require "./spec_helper"

# What the struct job below did. A plain counter object, not class variables: those fail this file's debug build
# ("MDNode context does not match Module context") on Crystal 1.22.
class LifecycleCounter
  INSTANCE = new

  property mode = "error"
  property runs = 0

  def self.mode : String
    INSTANCE.mode
  end

  def self.mode=(value : String)
    INSTANCE.mode = value
  end

  def self.runs : Int32
    INSTANCE.runs
  end

  def self.runs=(value : Int32)
    INSTANCE.runs = value
  end
end

class LifecyclePermanentError < JoobQ::NonRetryableError
end

# A struct job, as applications often write them: the failure bookkeeping must not depend on the job being a
# reference that every handler shares.
struct LifecycleJob
  include JoobQ::Job

  @queue = "lifecycle"

  def initialize
  end

  def perform
    LifecycleCounter.runs += 1
    case LifecycleCounter.mode
    when "permanent" then raise LifecyclePermanentError.new("card declined #{LifecycleCounter.runs}")
    when "huge"      then raise "x" * 100_000
    else                  raise "transient failure #{LifecycleCounter.runs}"
    end
  end
end

class LifecycleClassJob
  include JoobQ::Job

  @queue = "lifecycle_class"

  class_property runs : Int32 = 0

  def initialize
  end

  def perform
    LifecycleClassJob.runs += 1
    raise JoobQ::NonRetryableError.new("not worth retrying")
  end
end

def lifecycle_job(retries : Int32) : LifecycleJob
  job = LifecycleJob.new
  job.retries = retries
  job.max_retries = retries
  job
end

def start_lifecycle(job : LifecycleJob) : JoobQ::Worker(LifecycleJob)
  queue = JoobQ::Queue(LifecycleJob).new("lifecycle", 1)
  JoobQ.add job
  worker = JoobQ::Worker(LifecycleJob).new(1, Channel(Nil).new, queue)
  worker.run
  worker
end

def lifecycle_delayed(redis) : Array(String)
  redis.zrange(JoobQ::RedisStore::DELAYED_SET, 0, -1).map(&.to_s).select(&.includes?(%("queue":"lifecycle")))
end

def lifecycle_dead(redis) : Array(JSON::Any)
  redis.zrange(JoobQ::DeadLetterQueue::KEY, 0, -1).map { |raw| JSON.parse(raw.to_s) }.select { |job| job["queue"] == "lifecycle" }
end

module JoobQ
  describe "failure lifecycle" do
    redis = JoobQ.store.as(RedisStore).redis
    idle = -> { JoobQ.store.processing_queue_size("lifecycle") == 0 && redis.llen("lifecycle") == 0 }

    before_each do
      JoobQ.reset
      LifecycleCounter.runs = 0
      LifecycleCounter.mode = "error"
    end

    after_each do
      eventually(2.seconds) { JoobQ.store.processing_queue_size("lifecycle") == 0 }
      sleep 100.milliseconds
      JoobQ.reset
    end

    it "retries every failure once while the budget lasts, then dead-letters the job (retry lock outliving its retry)" do
      worker = start_lifecycle(lifecycle_job(3))

      # Each failure leaves exactly one retry, though the lock of the previous retry is still in Redis
      1.upto(3) do |run|
        eventually { LifecycleCounter.runs >= run && lifecycle_delayed(redis).size == 1 && idle.call }.should be_true
        LifecycleCounter.runs.should eq run
        redis.exists("joobq:retry_lock:#{JSON.parse(lifecycle_delayed(redis).first)["jid"]}").should eq 1
        JoobQ.config.schedulers.first.enqueue_due_jobs(current_time: 1.hour.from_now)
      end

      eventually { LifecycleCounter.runs >= 4 && lifecycle_dead(redis).size == 1 && idle.call }.should be_true
      worker.terminate

      LifecycleCounter.runs.should eq 4
      lifecycle_dead(redis).size.should eq 1
      lifecycle_delayed(redis).size.should eq 0
    end

    it "does not schedule the same failure twice" do
      queue = Queue(LifecycleJob).new("lifecycle", 1)
      job = lifecycle_job(3)
      job.retries = 2 # what the Retry middleware stores for its first retry (attempt 1)

      first, _ = ExponentialBackoff.retry_idempotent(job, queue, 1)
      second, _ = ExponentialBackoff.retry_idempotent(job, queue, 1)
      first.should be_true
      second.should be_false
      lifecycle_delayed(redis).size.should eq 1

      # The next failure of the job is another attempt and is scheduled
      job.retries = 1
      third, _ = ExponentialBackoff.retry_idempotent(job, queue, 2)
      third.should be_true
      lifecycle_delayed(redis).size.should eq 2
    end

    it "dead-letters a NonRetryableError at once, whatever retries are left" do
      LifecycleCounter.mode = "permanent"
      worker = start_lifecycle(lifecycle_job(3))
      eventually { lifecycle_dead(redis).size == 1 && idle.call }.should be_true
      sleep 200.milliseconds
      worker.terminate

      LifecycleCounter.runs.should eq 1
      lifecycle_delayed(redis).size.should eq 0
      dead = lifecycle_dead(redis).first
      dead["status"].should eq "dead"
      dead["error"]["error_class"].should eq "LifecyclePermanentError"
      dead["error"]["error_type"].should eq "non_retryable_error"
    end

    it "dead-letters a NonRetryableError raised by a class job" do
      LifecycleClassJob.runs = 0
      queue = Queue(LifecycleClassJob).new("lifecycle_class", 1)
      job = LifecycleClassJob.new
      job.retries = 5
      job.max_retries = 5
      JoobQ.add job
      worker = Worker(LifecycleClassJob).new(1, Channel(Nil).new, queue)
      worker.run
      dlq = DeadLetterQueue.new(redis)
      eventually { dlq.count("lifecycle_class") == 1 && JoobQ.store.processing_queue_size("lifecycle_class") == 0 }.should be_true
      worker.terminate

      LifecycleClassJob.runs.should eq 1
      redis.zrange(RedisStore::DELAYED_SET, 0, -1).map(&.to_s).count(&.includes?(%("queue":"lifecycle_class"))).should eq 0
    end

    it "classifies NonRetryableError and its subclasses as not to be retried" do
      queue = Queue(LifecycleJob).new("lifecycle", 1)
      context = ErrorContext.from_exception(lifecycle_job(3), queue, LifecyclePermanentError.new("no"), "w")
      context.error_type.should eq "non_retryable_error"
      context.should_retry?.should be_false
    end

    {0, 1}.each do |retries|
      it "keeps the error class, message and backtrace on a dead letter (struct job, #{retries} retries)" do
        worker = start_lifecycle(lifecycle_job(retries))
        if retries > 0
          eventually { lifecycle_delayed(redis).size == 1 && idle.call }.should be_true
          JoobQ.config.schedulers.first.enqueue_due_jobs(current_time: 1.hour.from_now)
        end
        eventually { lifecycle_dead(redis).size == 1 && idle.call }.should be_true
        worker.terminate

        error = lifecycle_dead(redis).first["error"]
        error.as_h?.should_not be_nil
        error["error_class"].should eq "Exception"
        error["message"].should eq "transient failure #{retries + 1}"
        error["backtrace"].as_s.should start_with "transient failure #{retries + 1} (Exception)\nfrom "
        error["failed_at"].as_s.should_not be_empty
        error["retry_count"].should eq retries

        # The reader's summary of the entry carries the message too
        entry = DeadLetterQueue.new(redis).page(0, 100, "lifecycle").first
        entry.error.should eq "transient failure #{retries + 1}"
      end
    end

    it "caps the stored message and backtrace" do
      LifecycleCounter.mode = "huge"
      worker = start_lifecycle(lifecycle_job(0))
      eventually { lifecycle_dead(redis).size == 1 && idle.call }.should be_true
      worker.terminate

      error = lifecycle_dead(redis).first["error"]
      error["backtrace"].as_s.bytesize.should be <= 8192
      error["message"].as_s.bytesize.should be <= 4096
      error["message"].as_s.should start_with "xxx"
    end
  end
end
