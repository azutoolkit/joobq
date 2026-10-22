require "./spec_helper"

module JoobQ
  describe WorkerRegistry do
    store = -> { JoobQ.store.as(RedisStore) }
    redis = -> { store.call.redis }

    before_each do
      redis.call.del(WorkerRegistry::INDEX)
    end

    it "publishes this process with live metrics" do
      registry = WorkerRegistry.new(store.call, id: "host-a:1")
      registry.beat

      info = WorkerRegistry.all(redis.call).find! { |w| w.id == "host-a:1" }
      info.status.should eq("running")
      info.pid.should eq(Process.pid)
      info.version.should eq(JoobQ::VERSION)
      info.rss_kb.should be > 0
      info.queues.should_not be_empty
      info.stale?.should be_false
    end

    it "skips an entry it cannot read instead of failing the whole list" do
      WorkerRegistry.new(store.call, id: "host-ok:1").beat
      redis.call.set(WorkerRegistry::PREFIX + "host-bad:2", "{not json")
      redis.call.zadd(WorkerRegistry::INDEX, Time.utc.to_unix_ms, "host-bad:2")
      redis.call.set(WorkerRegistry::PREFIX + "host-old:3", %({"id":"host-old:3"})) # an older format
      redis.call.zadd(WorkerRegistry::INDEX, Time.utc.to_unix_ms, "host-old:3")

      ids = WorkerRegistry.all(redis.call).map(&.id)

      ids.should contain("host-ok:1")
      ids.should_not contain("host-bad:2")
      ids.should_not contain("host-old:3")
    end

    it "removes the worker when stopped" do
      registry = WorkerRegistry.new(store.call, id: "host-b:2")
      registry.beat
      registry.stop

      WorkerRegistry.all(redis.call).map(&.id).should_not contain("host-b:2")
    end

    it "prunes workers whose heartbeat lapsed" do
      redis.call.zadd(WorkerRegistry::INDEX, Time.utc.to_unix_ms - 60_000, "host-c:3")

      WorkerRegistry.all(redis.call).map(&.id).should_not contain("host-c:3")
      redis.call.zscore(WorkerRegistry::INDEX, "host-c:3").should be_nil
    end

    it "heartbeats in the background until stopped" do
      registry = WorkerRegistry.new(store.call, id: "host-d:4")
      registry.start

      eventually { WorkerRegistry.all(redis.call).map(&.id).includes?("host-d:4") }.should be_true
      registry.stop
    end
  end
end
