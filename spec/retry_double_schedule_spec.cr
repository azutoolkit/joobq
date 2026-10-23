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
    else                   raise "boom"
    end
  end
end

def run_flaky_once(job : FlakyJob)
  queue = JoobQ::Queue(FlakyJob).new("flaky", 1)
  JoobQ.add job
  worker = JoobQ::Worker(FlakyJob).new(1, Channel(Nil).new, queue)
  worker.run
  eventually { FlakyJob.runs >= 1 }.should be_true
  sleep 300.milliseconds
  worker.terminate
end

module JoobQ
  describe "failed jobs" do
    redis = JoobQ.store.as(RedisStore).redis

    before_each do
      JoobQ.reset
      FlakyJob.runs = 0
    end

    it "are scheduled for retry once per attempt, not twice" do
      FlakyJob.mode = "error"
      job = FlakyJob.new
      job.retries = 2
      job.max_retries = 2
      run_flaky_once(job)

      redis.zcard(RedisStore::DELAYED_SET).should eq 1
      member = redis.zrange(RedisStore::DELAYED_SET, 0, 0, with_scores: true)
      # due in the future (backoff), not at once
      member[1].to_s.to_f.should be > Time.utc.to_unix_ms
    end

    it "go to the dead letter set once, without a retry, when the error cannot be fixed by running again" do
      FlakyJob.mode = "validation"
      job = FlakyJob.new
      job.retries = 2
      job.max_retries = 2
      run_flaky_once(job)

      DeadLetterQueue.new(redis).count.should eq 1
      redis.zcard(RedisStore::DELAYED_SET).should eq 0
      FlakyJob.runs.should eq 1
    end

    it "are dead-lettered once when the last attempt fails" do
      FlakyJob.mode = "error"
      job = FlakyJob.new
      job.retries = 0
      job.max_retries = 1
      run_flaky_once(job)

      DeadLetterQueue.new(redis).count.should eq 1
      redis.zcard(RedisStore::DELAYED_SET).should eq 0
    end
  end
end
