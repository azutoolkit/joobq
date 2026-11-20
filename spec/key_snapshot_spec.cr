require "./spec_helper"

module JoobQ
  # Golden snapshot: the exact Redis keys each operation creates on an empty DB.
  # Guards the key namespace: a change to any name here is a change of the on-disk layout.
  describe "Redis key snapshot" do
    redis = -> { JoobQ.store.as(RedisStore).redis }
    keys = -> { redis.call.keys("*").map(&.to_s).sort! }

    it "enqueue writes the queue list inside the joobq:v1: namespace" do
      JoobQ.store.enqueue(ExampleJob.new(1))

      keys.call.should eq(["joobq:v1:queue:example"])
    end

    it "a delayed schedule writes the delayed sorted set" do
      JoobQ.store.as(RedisStore).schedule(ExampleJob.new(1), Time.utc.to_unix_ms + 60_000)

      keys.call.should eq(["joobq:v1:delayed_jobs"])
    end

    it "move_to_dead_letter writes the dead letter set, its counts and the stats hashes" do
      JoobQ.store.as(RedisStore).move_to_dead_letter(ExampleJob.new(1), "example")

      keys.call.should eq(%w[
        joobq:v1:dead_letter joobq:v1:dead_letter:counts
        joobq:v1:stats:dead_letter joobq:v1:stats:total_dead_letter
      ])
    end

    it "move_to_retry writes the delayed set and the retry stats hashes" do
      JoobQ.store.as(RedisStore).move_to_retry(ExampleJob.new(1), "example", 60_000_i64).should be_true

      keys.call.should eq(%w[joobq:v1:delayed_jobs joobq:v1:stats:retries joobq:v1:stats:total_retries])
    end

    it "a worker heartbeat writes its entry and the workers index" do
      WorkerRegistry.new(JoobQ.store.as(RedisStore), id: "snap-host:1").beat

      keys.call.should eq(["joobq:v1:worker:snap-host:1", "joobq:v1:workers"])
    end

    it "a lifecycle event on the Redis sink writes only the events stream" do
      # The pub/sub channel joobq:v1:events:live is not a key, so it never shows here.
      RedisEventSink.new(redis.call).publish(Event.new("job.dead", JSON.parse(%({"jid":"j1"}))))

      keys.call.should eq(["joobq:v1:events"])
    end
  end
end
