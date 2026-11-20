require "./spec_helper"

# 0.6 kept waiting jobs under the bare queue name and its other keys under `joobq:` with no version. `migrate_keyspace!`
# moves them into `joobq:v1:` once no other process is live, and does nothing the second time.
module JoobQ
  describe "migrating a 0.6 keyspace" do
    store = JoobQ.store.as(RedisStore)
    redis = store.redis
    queue = "mig_q"
    jobs = (0..6).map { |n| ExampleJob.new(n).tap { |j| j.queue = queue }.to_json }
    job = ->(n : Int32) { jobs[n] }

    old_keys = [
      queue, "joobq:processing:#{queue}:host:1", "joobq:processing:#{queue}", "joobq:processing-owners",
      "joobq:delayed_jobs", "joobq:dead_letter", "joobq:dead_letter:counts", "joobq:stats:processed",
      "joobq:retry_lock:abc", "joobq:queue:#{queue}:paused", "joobq:queue:#{queue}:config", "joobq:worker:host:1",
      "joobq:workers", "joobq:events", "joobq:error_counts", "joobq:delivery-bridge:#{queue}", "unrelated_app_key",
      "other_unlisted_queue",
    ]
    new_keys = [
      Keys.queue(queue), Keys.processing(queue, "host:1"), Keys.processing(queue), Keys::PROCESSING_OWNERS, Keys::DELAYED_JOBS,
      Keys::DEAD_LETTER, Keys::DEAD_LETTER_COUNTS, Keys.stat("processed"), Keys.retry_lock("abc"), Keys.paused(queue),
      Keys.config(queue), Keys.worker("host:1"), Keys::WORKERS, Keys::EVENTS, Keys::ERROR_COUNTS, Keys.delivery_bridge(queue),
    ]
    clean = -> { redis.del(old_keys + new_keys) }

    # The shapes 0.6 wrote
    seed = -> do
      redis.rpush(queue, job.call(1), job.call(2))
      redis.rpush("joobq:processing:#{queue}:host:1", job.call(3))
      redis.rpush("joobq:processing:#{queue}", job.call(4))
      redis.zadd("joobq:delayed_jobs", 1000, job.call(5))
      redis.zadd("joobq:dead_letter", 1000, job.call(6))
      redis.hset("joobq:dead_letter:counts", queue, 1)
      redis.hset("joobq:stats:processed", queue, 7)
      redis.set("joobq:retry_lock:abc", "attempt:1")
      redis.set("joobq:queue:#{queue}:paused", "1")
      redis.hset("joobq:queue:#{queue}:config", "concurrency", "3")
      redis.set("joobq:worker:host:1", "{}")
      redis.zadd("joobq:workers", 1, "host:1")
      redis.command(["XADD", "joobq:events", "*", "type", "job.enqueued"])
      redis.hset("joobq:error_counts", "E", 2)
      redis.set("joobq:delivery-bridge:#{queue}", "1")
      redis.set("unrelated_app_key", "keep")
      redis.rpush("other_unlisted_queue", "keep")
    end

    before_each do
      clean.call
      seed.call
    end
    after_each { clean.call }

    it "moves every 0.6 key of the listed queues under joobq:v1:, contents intact" do
      report = JoobQ.migrate_keyspace!(queues: [queue])

      report.renamed.should eq(15)
      report.skipped.should be_empty
      store.queue_size(queue).should eq(2)
      redis.lrange(Keys.queue(queue), 0, -1).map(&.to_s).should eq([job.call(1), job.call(2)])
      redis.lrange(Keys.processing(queue, "host:1"), 0, -1).should eq([job.call(3)])
      redis.lrange(Keys.processing(queue), 0, -1).should eq([job.call(4)])
      redis.zscore(Keys::DELAYED_JOBS, job.call(5)).should eq("1000")
      redis.zscore(Keys::DEAD_LETTER, job.call(6)).should eq("1000")
      redis.hget(Keys::DEAD_LETTER_COUNTS, queue).should eq("1")
      redis.hget(Keys.stat("processed"), queue).should eq("7")
      redis.get(Keys.retry_lock("abc")).should eq("attempt:1")
      store.paused?(queue).should be_true
      redis.hget(Keys.config(queue), "concurrency").should eq("3")
      redis.get(Keys.worker("host:1")).should eq("{}")
      redis.zscore(Keys::WORKERS, "host:1").should_not be_nil
      redis.command(["XLEN", Keys::EVENTS]).should eq(1)
      redis.hget(Keys::ERROR_COUNTS, "E").should eq("2")
      redis.get(Keys.delivery_bridge(queue)).should eq("1")
      old_keys.first(old_keys.size - 2).each { |key| redis.exists(key).should eq(0) }
    end

    it "leaves another application's keys and unlisted queues alone" do
      JoobQ.migrate_keyspace!(queues: [queue])

      redis.get("unrelated_app_key").should eq("keep")
      redis.lrange("other_unlisted_queue", 0, -1).should eq(["keep"])
    end

    it "does nothing the second time" do
      JoobQ.migrate_keyspace!(queues: [queue])
      again = JoobQ.migrate_keyspace!(queues: [queue])

      again.renamed.should eq(0)
      again.skipped.should be_empty
      store.queue_size(queue).should eq(2)
    end

    it "does not overwrite a key that already exists in the new namespace" do
      redis.rpush(Keys.queue(queue), "already here")

      report = JoobQ.migrate_keyspace!(queues: [queue])

      report.skipped.should eq([queue])
      redis.lrange(Keys.queue(queue), 0, -1).should eq(["already here"])
      redis.llen(queue).should eq(2) # still there, for the operator to decide
    end

    it "refuses while another process is live, and moves nothing" do
      redis.zadd("joobq:processing-owners", store.redis_now_ms, "otherhost:99")

      expect_raises(KeyspaceMigrationError, /otherhost:99/) { JoobQ.migrate_keyspace!(queues: [queue]) }

      redis.llen(queue).should eq(2)
      redis.exists(Keys.queue(queue)).should eq(0)
    end

    it "does not count a lapsed owner or this process as live" do
      redis.zadd("joobq:processing-owners", store.redis_now_ms - 120_000, "deadhost:1")
      redis.zadd("joobq:processing-owners", store.redis_now_ms, store.owner_id)

      JoobQ.migrate_keyspace!(queues: [queue]).renamed.should eq(16) # the 15 keys, and the owners set
    end

    it "warns once per process while 0.6 keys remain" do
      Keyspace.reset_warning
      Keyspace.warn_once(store, [queue]).should be_true
      Keyspace.warn_once(store, [queue]).should be_false
      Keyspace.reset_warning
      JoobQ.migrate_keyspace!(queues: [queue])
      Keyspace.warn_once(store, [queue]).should be_false
    end

    it "reports the 0.6 keys a queue still has" do
      JoobQ.legacy_keyspace?(queues: [queue]).should be_true
      JoobQ.migrate_keyspace!(queues: [queue])
      JoobQ.legacy_keyspace?(queues: [queue]).should be_false
    end
  end
end
