require "./spec_helper"

module JoobQ
  # Split-brain: RedisStore.instance is built from ENV and is not JoobQ.store.
  # Classes defaulting to RedisStore.instance.redis ignore a reconfigured store.
  describe "store wiring" do
    env_port = ENV.fetch("REDIS_PORT", "6379").to_i
    other_port = env_port == 6392 ? 6391 : 6392

    it "current behaviour: DeadLetterQueue.new and WorkerRegistry.all follow the ENV instance, not config.store" do
      original = JoobQ.config.store
      other = RedisStore.new(host: "localhost", port: other_port)
      begin
        other.redis.ping
      rescue Redis::CannotConnectError
        pending!("needs a second Redis on port #{other_port}")
      end

      begin
        JoobQ.config.store = other
        JoobQ.store.same?(other).should be_true
        RedisStore.instance.same?(other).should be_false

        job = ExampleJob.new(1)
        job.queue = "example"
        DeadLetterQueue.add(DeadLetterQueue.new.@redis, 1000_i64, [job.to_json])

        RedisStore.instance.redis.zcard(DeadLetterQueue::KEY).should eq(1)
        other.redis.zcard(DeadLetterQueue::KEY).should eq(0)
        DeadLetterQueue.new.count.should eq(1)

        RedisStore.instance.redis.zadd(WorkerRegistry::INDEX, Time.utc.to_unix_ms, "wiring:1")
        WorkerRegistry.new.@store.same?(RedisStore.instance).should be_true
        other.redis.zcard(WorkerRegistry::INDEX).should eq(0)
      ensure
        JoobQ.config.store = original
        other.redis.flushdb
        RedisStore.instance.redis.flushdb
      end
    end

    it "current behaviour: with the default store, JoobQ.store.redis and RedisStore.instance.redis reach the same server" do
      JoobQ.store.as(RedisStore).redis.set("wiring:probe", "ok")

      RedisStore.instance.redis.get("wiring:probe").should eq("ok")
    ensure
      RedisStore.instance.redis.del("wiring:probe")
    end
  end
end
