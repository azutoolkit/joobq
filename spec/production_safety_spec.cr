require "./spec_helper"

class AuditBlockingJob
  include JoobQ::Job
  SIGNAL  = Channel(Nil).new(100)
  RELEASE = Channel(Nil).new(100)

  def initialize
    @queue = "audit_blocking"
  end

  def perform
    SIGNAL.send(nil)
    RELEASE.receive
  end
end

module JoobQ
  describe "production safety regressions" do
    it "retains a delayed job when its destination is not writable" do
      store = JoobQ.config.store.as(RedisStore)
      job = ExampleJob.new(1).to_json
      store.schedule_job(job, 0_i64)
      store.redis.set("example", "wrong-type")
      store.process_due_delayed_jobs("example")
      store.redis.zscore(RedisStore::DELAYED_SET, job).should_not be_nil
    end

    it "retains the processing copy if writing the dead letter fails" do
      store = JoobQ.config.store.as(RedisStore)
      job = ExampleJob.new(1)
      raw = job.to_json
      store.redis.rpush("joobq:processing:example", raw)
      store.redis.set(DeadLetterQueue::KEY, "wrong-type")
      expect_raises(Redis::Error) { store.move_to_dead_letter(job, "example") }
      store.redis.lrange("joobq:processing:example", 0, -1).should eq([raw])
    end

    it "propagates DLQ settlement failure to the worker boundary" do
      store = JoobQ.config.store.as(RedisStore)
      queue = Queue(ExampleJob).new("example", 1)
      job = ExampleJob.new(1)
      context = ErrorContext.from_exception(job, queue, ArgumentError.new("invalid"), "worker")
      store.redis.set(DeadLetterQueue::KEY, "wrong-type")
      expect_raises(Redis::Error) { ErrorHandler.send_to_dead_letter(job, queue, context) }
    end

    it "keeps malformed payloads recoverable when DLQ storage fails" do
      store = JoobQ.config.store.as(RedisStore)
      raw = "not-json"
      store.redis.set(DeadLetterQueue::KEY, "wrong-type")
      store.redis.rpush("example", raw)
      queue = Queue(ExampleJob).new("example", 1)
      worker = Worker(ExampleJob).new(1, Channel(Nil).new(1), queue)
      worker.run
      eventually { store.redis.llen("example") == 0 }.should be_true
      eventually { worker.in_progress == 0 }.should be_true
      store.redis.lrange("joobq:processing:example", 0, -1).should eq([raw])
    ensure
      worker.try(&.terminate)
    end

    it "promotes once under competing schedulers and preserves large integers" do
      store = JoobQ.config.store.as(RedisStore)
      raw = %({"queue":"audit_due","id":9223372036854775807})
      store.schedule_job(raw, 0_i64)
      done = Channel(Exception?).new(20)
      20.times do
        spawn do
          store.process_due_delayed_jobs("audit_due")
          done.send(nil)
        rescue ex
          done.send(ex)
        end
      end
      20.times do
        select
        when error = done.receive
          raise error if error
        when timeout(5.seconds)
          fail "scheduler did not finish"
        end
      end
      jobs = store.redis.lrange("audit_due", 0, -1)
      jobs.size.should eq(1)
      JSON.parse(jobs.first.as(String))["id"].as_i64.should eq(Int64::MAX)
      store.redis.zcard(RedisStore::DELAYED_SET).should eq(0)
    end

    it "bounds a stalled Redis command and reconnects for a later command" do
      store = RedisStore.new(command_timeout: 30.milliseconds)
      store.redis.ping.should eq("PONG")
      JoobQ.config.store.as(RedisStore).redis.command(["CLIENT", "PAUSE", "150", "ALL"])
      started = Time.instant
      expect_raises(RedisOutcomeUnknown, /outcome is unknown/) { store.redis.ping }
      (Time.instant - started).should be < 1.second
      sleep 250.milliseconds
      store.redis.ping.should eq("PONG")
    end

    it "does not exceed the per-worker batch capacity while jobs are blocked" do
      previous = JoobQ.config.worker_batch_size
      JoobQ.config.worker_batch_size = 2
      queue = Queue(AuditBlockingJob).new("audit_blocking", 1)
      worker = Worker(AuditBlockingJob).new(1, Channel(Nil).new(1), queue)
      20.times { queue.add(AuditBlockingJob.new) }
      worker.run
      2.times do
        select
        when AuditBlockingJob::SIGNAL.receive
        when timeout(3.seconds)
          fail "worker did not start a job"
        end
      end
      sleep 150.milliseconds
      queue.size.should eq(18)
    ensure
      worker.try(&.terminate)
      20.times { AuditBlockingJob::RELEASE.send(nil) }
      eventually { InFlight.count == 0 }.should be_true
      JoobQ.config.worker_batch_size = previous || 10
    end
  end
end
