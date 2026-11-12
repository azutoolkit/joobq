require "./spec_helper"

# Two `Queue` instances of one name in one process share the process's `owner_id`, so they share one processing list
# `joobq:processing:<queue>:<owner>`. Starting the second must not run restart recovery (`include_self`): that would
# drain the first instance's in-flight jobs back to the queue head and run them twice. Recovery after every instance
# of the name has stopped is unchanged.
module JoobQ
  class DuplicateStartJob
    include JoobQ::Job

    # What ran, in order; `RELEASE` holds every "blocker" job inside `perform` until the example releases it.
    LOG     = [] of String
    LOCK    = Sync::Mutex.new
    RELEASE = Atomic(Bool).new(false)

    getter label : String

    def initialize(@label : String = "", queue : String = "dup_start_unused")
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

  describe "starting a second Queue instance of a running queue name" do
    store = JoobQ.store.as(RedisStore)
    redis = store.redis
    owned = ->(name : String) { "joobq:processing:#{name}:#{store.owner_id}" }
    name = ""

    before_each do
      DuplicateStartJob.reset
      name = "dup_start_#{Random::Secure.hex(4)}"
    end

    after_each do
      DuplicateStartJob::RELEASE.set(true)
      redis.del(name, owned.call(name))
    end

    it "does not re-queue the first instance's in-flight job" do
      a = Queue(DuplicateStartJob).new(name, 1)
      b = Queue(DuplicateStartJob).new(name, 1)
      begin
        a.add(DuplicateStartJob.new("blocker", name).to_json)
        a.start
        eventually { DuplicateStartJob.runs("blocker") == 1 }.should be_true
        redis.llen(owned.call(name)).should eq(1)

        b.start

        # A re-queued job would run a second time (B's workers claim it) while the first is still blocked.
        eventually(400.milliseconds) { DuplicateStartJob.runs("blocker") > 1 }.should be_false
        redis.llen(owned.call(name)).should eq(1)
        redis.llen(name).should eq(0)

        DuplicateStartJob::RELEASE.set(true)
        eventually { redis.llen(owned.call(name)) == 0 }.should be_true
        DuplicateStartJob.runs("blocker").should eq(1)
        redis.llen(name).should eq(0)
      ensure
        DuplicateStartJob::RELEASE.set(true)
        a.stop!
        b.stop!
      end
    end
  end
end
