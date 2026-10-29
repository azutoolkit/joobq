require "./spec_helper"

module JoobQ
  # RedisStore.instance follows the configured store, so classes that default to it
  # (DeadLetterQueue, WorkerRegistry, schedulers, the event sink) use the same Redis as the queues.
  #
  # The cross-server example needs a SECOND, throwaway Redis and is opt-in: set
  # JOOBQ_SPEC_SECOND_REDIS_PORT to its port (host: REDIS_HOST or localhost). It must be a
  # different server from the REDIS_PORT one. Nothing is flushed; only the keys the example
  # writes are deleted.
  describe "store wiring" do
    env_host = ENV["REDIS_HOST"]? || "localhost"
    env_port = ENV.fetch("REDIS_PORT", "6379").to_i
    second_port = ENV["JOOBQ_SPEC_SECOND_REDIS_PORT"]?.try(&.to_i?)

    it "RedisStore.instance is the configured store" do
      JoobQ.store.same?(RedisStore.instance).should be_true
    end

    it "classes that default to the instance use the configured store when it is replaced" do
      original = JoobQ.config.store
      replacement = RedisStore.new(host: env_host, port: env_port)
      begin
        JoobQ.config.store = replacement

        RedisStore.instance.same?(replacement).should be_true
        DeadLetterQueue.new.@redis.same?(replacement.redis).should be_true
        WorkerRegistry.new.@store.same?(replacement).should be_true
        DelayedJobScheduler.new.@store.same?(replacement).should be_true
      ensure
        JoobQ.config.store = original
      end
    end

    it "writes land on the configured store's server, not on a separate ENV-built one" do
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

        job = ExampleJob.new(1)
        job.queue = "example"
        DeadLetterQueue.add(DeadLetterQueue.new.@redis, 1000_i64, [job.to_json])

        other.redis.zcard(DeadLetterQueue::KEY).should eq(1)
        original.as(RedisStore).redis.zcard(DeadLetterQueue::KEY).should eq(0)
        DeadLetterQueue.new.count.should eq(1)
      ensure
        JoobQ.config.store = original
        [
          -> { other.redis.del(DeadLetterQueue::KEY) },
          -> { other.redis.del(DeadLetterQueue::COUNTS) },
        ].each do |cleanup|
          begin
            cleanup.call
          rescue
          end
        end
      end
    end
  end
end
