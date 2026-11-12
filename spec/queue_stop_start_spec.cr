require "./spec_helper"

# `Queue#stop!` returns while a long-running job is still executing (each claimed job runs in its own fiber) and
# deregisters the instance. A NEW instance of the same name then counts as the first one and its restart recovery
# would drain the still-running job back to the queue head: it would run twice. Recovery must be skipped while this
# process still has a claim for the queue name, and must still run when nothing is in flight.
module JoobQ
  class StopStartJob
    include JoobQ::Job

    # What ran, in order; `RELEASE` holds every "blocker" job inside `perform` until the example releases it.
    LOG     = [] of String
    LOCK    = Sync::Mutex.new
    RELEASE = Atomic(Bool).new(false)

    getter label : String

    def initialize(@label : String = "", queue : String = "stop_start_unused")
      @queue = queue
    end

    def perform
      LOCK.synchronize { LOG << @label }
      return unless @label == "blocker"
      until RELEASE.get
        sleep 5.milliseconds
      end
    end

    def self.runs(label : String) : Int32
      LOCK.synchronize { LOG.count(label) }
    end

    def self.reset : Nil
      LOCK.synchronize { LOG.clear }
      RELEASE.set(false)
    end
  end

  describe "starting a Queue instance after another of the same name was stopped with a job still running" do
    store = JoobQ.store.as(RedisStore)
    redis = store.redis
    owned = ->(name : String) { "joobq:processing:#{name}:#{store.owner_id}" }
    name = ""

    before_each do
      StopStartJob.reset
      name = "stop_start_#{Random::Secure.hex(4)}"
    end

    after_each do
      StopStartJob::RELEASE.set(true)
      redis.del(name, owned.call(name))
    end

    it "does not re-queue a job that is still running after stop!" do
      a = Queue(StopStartJob).new(name, 1)
      b = Queue(StopStartJob).new(name, 1)
      begin
        a.add(StopStartJob.new("blocker", name).to_json)
        a.start
        eventually { StopStartJob.runs("blocker") == 1 }.should be_true
        redis.llen(owned.call(name)).should eq(1)

        a.stop!
        StopStartJob.runs("blocker").should eq(1)
        redis.llen(owned.call(name)).should eq(1)

        b.start

        # A re-queued job would run a second time (B's worker claims it) while the first is still blocked.
        eventually(400.milliseconds) { StopStartJob.runs("blocker") > 1 }.should be_false
        redis.llen(owned.call(name)).should eq(1)
        redis.llen(name).should eq(0)

        StopStartJob::RELEASE.set(true)
        eventually { redis.llen(owned.call(name)) == 0 }.should be_true
        StopStartJob.runs("blocker").should eq(1)
        redis.llen(name).should eq(0)
      ensure
        StopStartJob::RELEASE.set(true)
        a.stop!
        b.stop!
      end
    end

    it "still recovers a stranded job once the earlier instance's job has finished" do
      a = Queue(StopStartJob).new(name, 1)
      b = Queue(StopStartJob).new(name, 1)
      begin
        a.add(StopStartJob.new("blocker", name).to_json)
        a.start
        eventually { StopStartJob.runs("blocker") == 1 }.should be_true
        a.stop!

        StopStartJob::RELEASE.set(true)
        eventually { redis.llen(owned.call(name)) == 0 && InFlight.count == 0 }.should be_true
        StopStartJob.runs("blocker").should eq(1)

        redis.lpush(owned.call(name), StopStartJob.new("stranded", name).to_json)
        redis.llen(owned.call(name)).should eq(1)

        b.start

        eventually { StopStartJob.runs("stranded") == 1 }.should be_true
        eventually { redis.llen(owned.call(name)) == 0 }.should be_true
        StopStartJob.runs("stranded").should eq(1)
        StopStartJob.runs("blocker").should eq(1)
      ensure
        StopStartJob::RELEASE.set(true)
        a.stop!
        b.stop!
      end
    end
  end
end
