require "./spec_helper"

class FlakyJob
  include JoobQ::Job

  @queue = "flaky"

  class_property mode = "error"
  class_property runs : Int32 = 0

  def initialize
  end

  def perform
    FlakyJob.runs += 1
    case FlakyJob.mode
    when "validation" then raise ArgumentError.new("bad argument")
    when "key"        then raise KeyError.new("missing key")
    when "notimpl"    then raise NotImplementedError.new("not built")
    else                   raise "boom"
    end
  end
end

# Starts a worker for the job and returns it; the caller terminates it.
def start_flaky(job : FlakyJob) : JoobQ::Worker(FlakyJob)
  queue = JoobQ::Queue(FlakyJob).new("flaky", 1)
  JoobQ.add job
  worker = JoobQ::Worker(FlakyJob).new(1, Channel(Nil).new, queue)
  worker.run
  worker
end

def flaky_job(retries : Int32) : FlakyJob
  job = FlakyJob.new
  job.retries = retries
  job.max_retries = retries
  job
end

module JoobQ
  describe "failed jobs" do
    redis = JoobQ.store.as(RedisStore).redis
    dlq = DeadLetterQueue.new(redis)
    idle = -> { JoobQ.store.processing_queue_size("flaky") == 0 && redis.llen("flaky") == 0 }

    before_each do
      JoobQ.reset
      FlakyJob.runs = 0
    end

    it "are scheduled for retry once per attempt, not twice" do
      FlakyJob.mode = "error"
      worker = start_flaky(flaky_job(2))
      eventually { FlakyJob.runs >= 1 && idle.call }.should be_true
      worker.terminate

      redis.zcard(RedisStore::DELAYED_SET).should eq 1
      score = redis.zrange(RedisStore::DELAYED_SET, 0, 0, with_scores: true)[1].to_s.to_f
      score.should be > Time.utc.to_unix_ms # due after the backoff, not at once
    end

    {"error", "validation", "key", "notimpl"}.each do |mode|
      it "are retried up to their budget and then dead-lettered exactly once (#{mode} error)" do
        FlakyJob.mode = mode
        worker = start_flaky(flaky_job(1))
        eventually { FlakyJob.runs >= 1 && redis.zcard(RedisStore::DELAYED_SET) == 1 }.should be_true

        JoobQ.config.schedulers.first.enqueue_due_jobs(current_time: 1.hour.from_now)
        eventually { FlakyJob.runs >= 2 && dlq.count >= 1 && idle.call }.should be_true
        worker.terminate

        FlakyJob.runs.should eq 2
        dlq.count.should eq 1
        redis.zcard(RedisStore::DELAYED_SET).should eq 0
      end
    end

    it "are dead-lettered once when the last attempt fails" do
      FlakyJob.mode = "error"
      worker = start_flaky(flaky_job(0))
      eventually { dlq.count >= 1 && idle.call }.should be_true
      worker.terminate

      dlq.count.should eq 1
      redis.zcard(RedisStore::DELAYED_SET).should eq 0
      FlakyJob.runs.should eq 1
    end

    it "an expired job is dead-lettered once and not also scheduled for retry" do
      job = flaky_job(2)
      job.expires = Time.utc.to_unix_ms - 1000
      worker = start_flaky(job)
      eventually { dlq.count >= 1 && idle.call }.should be_true
      worker.terminate

      FlakyJob.runs.should eq 0
      dlq.count.should eq 1
      redis.zcard(RedisStore::DELAYED_SET).should eq 0
    end

    it "ErrorHandler.schedule_retry scores the retry at now plus the delay" do
      queue = Queue(FlakyJob).new("flaky", 1)
      job = flaky_job(2)
      context = ErrorContext.from_exception(job, queue, RuntimeError.new("x"), "w")
      before = Time.utc.to_unix_ms
      ErrorHandler.schedule_retry(job, queue, context)

      score = redis.zrange(RedisStore::DELAYED_SET, 0, 0, with_scores: true)[1].to_s.to_f
      score.should be >= before + context.retry_delay.total_milliseconds
    end
  end
end
