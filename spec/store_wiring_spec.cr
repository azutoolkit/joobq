require "./spec_helper"

module JoobQ
  # Split-brain: RedisStore.instance is built from ENV and is not JoobQ.store.
  # Classes defaulting to RedisStore.instance.redis ignore a reconfigured store.
  #
  # The split-brain example needs a SECOND, throwaway Redis and is opt-in: set
  # JOOBQ_SPEC_SECOND_REDIS_PORT to its port (host: REDIS_HOST or localhost). It must be a
  # different server from the REDIS_PORT one. Nothing is flushed; only the keys the example
  # writes are deleted.
  describe "store wiring" do
    env_host = ENV["REDIS_HOST"]? || "localhost"
    env_port = ENV.fetch("REDIS_PORT", "6379").to_i
    second_port = ENV["JOOBQ_SPEC_SECOND_REDIS_PORT"]?.try(&.to_i?)

    it "current behaviour: DeadLetterQueue.new and WorkerRegistry.new follow the ENV instance, not config.store" do
      other_port = second_port
      if other_port.nil?
        pending!("set JOOBQ_SPEC_SECOND_REDIS_PORT to a throwaway Redis to run this example")
        next
      end
      if other_port == env_port
        pending!("JOOBQ_SPEC_SECOND_REDIS_PORT must differ from REDIS_PORT (#{env_port}): two different servers are required")
        next
      end

      original = JoobQ.config.store
      other = RedisStore.new(host: env_host, port: other_port)
      begin
        other.redis.ping
      rescue Redis::CannotConnectError
        pending!("needs a second Redis on port #{other_port}")
        next
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
        redis = RedisStore.instance.redis
        [
          -> { redis.del(DeadLetterQueue::KEY) },
          -> { redis.del(DeadLetterQueue::COUNTS) },
          -> { redis.zrem(WorkerRegistry::INDEX, "wiring:1") },
        ].each do |cleanup|
          begin
            cleanup.call
          rescue
          end
        end
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
