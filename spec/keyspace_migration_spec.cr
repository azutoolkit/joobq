require "./spec_helper"

# 0.6 kept waiting jobs under the bare queue name and its other keys under `joobq:` with no version. `migrate_keyspace!`
# moves them into `joobq:v1:` once no other process is live, and does nothing the second time.
module JoobQ
  class MigratedJob
    include JoobQ::Job

    RAN = Atomic(Int32).new(0)

    def initialize(queue : String = "migrated_unused")
      @queue = queue
    end

    def perform
      RAN.add(1)
    end
  end

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
    existing = ->(keys : Array(String)) { keys.count { |key| redis.exists(key) == 1 } }

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

    describe "when the new version already created keys of its own" do
      it "drops the stale transient keys (owners, workers, events) and keeps the new ones" do
        redis.zadd(Keys::PROCESSING_OWNERS, 5, "newhost:1")
        redis.zadd("joobq:processing-owners", store.redis_now_ms - 120_000, "deadhost:1")
        redis.zadd(Keys::WORKERS, 5, "new:1")
        redis.set(Keys.worker("host:1"), "new")
        redis.command(["XADD", Keys::EVENTS, "*", "type", "new"])

        report = JoobQ.migrate_keyspace!(queues: [queue])

        report.skipped.should be_empty
        existing.call(["joobq:processing-owners", "joobq:workers", "joobq:worker:host:1", "joobq:events"]).should eq(0)
        redis.zrange(Keys::WORKERS, 0, -1).should eq(["new:1"])
        redis.get(Keys.worker("host:1")).should eq("new")
        redis.command(["XLEN", Keys::EVENTS]).should eq(1)
      end

      it "puts the old jobs of a list at the head of the new list, in order" do
        redis.rpush(Keys.queue(queue), "already here")

        report = JoobQ.migrate_keyspace!(queues: [queue])

        report.skipped.should be_empty
        redis.lrange(Keys.queue(queue), 0, -1).map(&.to_s).should eq([job.call(1), job.call(2), "already here"])
        redis.exists(queue).should eq(0)
      end

      it "unites sorted sets and adds numeric counters, keeping the new value of the rest" do
        redis.zadd(Keys::DELAYED_JOBS, 2000, "new-delayed")
        redis.zadd(Keys::DEAD_LETTER, 3000, job.call(6)) # the same member: the later score stays
        redis.hset(Keys.stat("processed"), queue, 3)
        redis.hset(Keys::DEAD_LETTER_COUNTS, queue, 2)
        redis.hset(Keys.config(queue), "concurrency", "9")
        redis.set(Keys.paused(queue), "0")

        JoobQ.migrate_keyspace!(queues: [queue]).skipped.should be_empty

        redis.zscore(Keys::DELAYED_JOBS, job.call(5)).should eq("1000")
        redis.zscore(Keys::DELAYED_JOBS, "new-delayed").should eq("2000")
        redis.zcard(Keys::DEAD_LETTER).should eq(1)
        redis.zscore(Keys::DEAD_LETTER, job.call(6)).should eq("3000")
        redis.hget(Keys.stat("processed"), queue).should eq("10")
        redis.hget(Keys::DEAD_LETTER_COUNTS, queue).should eq("3")
        redis.hget(Keys.config(queue), "concurrency").should eq("9")
        redis.get(Keys.paused(queue)).should eq("0")
        existing.call(["joobq:delayed_jobs", "joobq:dead_letter", "joobq:stats:processed", "joobq:queue:#{queue}:config"]).should eq(0)
      end

      it "adds a counter once, however often the migration runs, and never raises on a non-integer field" do
        redis.hset(Keys.stat("processed"), queue, 3)
        redis.hset(Keys.stat("processed"), "text", "not a number") # in the new hash
        redis.hset("joobq:stats:processed", "text", "5")           # numeric in the old one: the new value stays
        redis.hset("joobq:stats:processed", "other", "word")       # not numeric in the old one: kept only if absent
        redis.hset(Keys.stat("processed"), "other", "9")

        JoobQ.migrate_keyspace!(queues: [queue])
        JoobQ.migrate_keyspace!(queues: [queue])

        redis.hget(Keys.stat("processed"), queue).should eq("10") # 3 + 7, once
        redis.hget(Keys.stat("processed"), "text").should eq("not a number")
        redis.hget(Keys.stat("processed"), "other").should eq("9")
        redis.exists("joobq:stats:processed").should eq(0)
      end

      it "merges a hash and deletes the old one in a single step, so an interrupted run cannot add twice" do
        redis.hset("joobq:stats:processed", "a", "4")
        redis.hset(Keys.stat("processed"), "a", "1")

        Keyspace.merge_hash(redis, "joobq:stats:processed", Keys.stat("processed"), true)

        redis.hget(Keys.stat("processed"), "a").should eq("5")
        redis.exists("joobq:stats:processed").should eq(0)
        # a second call finds nothing left to add
        Keyspace.merge_hash(redis, "joobq:stats:processed", Keys.stat("processed"), true)
        redis.hget(Keys.stat("processed"), "a").should eq("5")
      end

      it "is still idempotent after a merge" do
        redis.rpush(Keys.queue(queue), "already here")
        JoobQ.migrate_keyspace!(queues: [queue])

        again = JoobQ.migrate_keyspace!(queues: [queue])

        again.renamed.should eq(0)
        again.merged.should eq(0)
        redis.llen(Keys.queue(queue)).should eq(3)
      end

      it "keeps the waiting jobs of a queue named like a transient key, whose v1 list already exists" do
        names = ["events", "workers", "worker:x", "delivery-bridge:q", "events:trim_lock"]
        begin
          names.each do |name|
            redis.rpush(name, "#{name} old 1", "#{name} old 2")
            redis.rpush(Keys.queue(name), "#{name} new")
          end

          report = JoobQ.migrate_keyspace!(queues: names)

          report.skipped.should be_empty
          names.each do |name|
            redis.lrange(Keys.queue(name), 0, -1).map(&.to_s).should eq(["#{name} old 1", "#{name} old 2", "#{name} new"])
            redis.exists(name).should eq(0)
          end
          report.merged.should be >= names.size
        ensure
          redis.del(names + names.map { |name| Keys.queue(name) })
        end
      end

      it "renames the list of a queue named like a transient key when no v1 list exists" do
        names = ["events", "workers", "worker:x", "delivery-bridge:q"]
        begin
          names.each { |name| redis.rpush(name, "#{name} 1", "#{name} 2") }

          report = JoobQ.migrate_keyspace!(queues: names)

          report.skipped.should be_empty
          names.each do |name|
            redis.lrange(Keys.queue(name), 0, -1).map(&.to_s).should eq(["#{name} 1", "#{name} 2"])
            redis.exists(name).should eq(0)
          end
        ensure
          redis.del(names + names.map { |name| Keys.queue(name) })
        end
      end

      it "still drops every stale legacy transient key under joobq: when the new one exists" do
        keys = {
          "joobq:events"            => Keys::EVENTS,
          "joobq:events:trim_lock"  => Keys::EVENTS_TRIM_LOCK,
          "joobq:workers"           => Keys::WORKERS,
          "joobq:worker:x"          => Keys.worker("x"),
          "joobq:delivery-bridge:q" => Keys.delivery_bridge("q"),
        }
        begin
          keys.each do |old, new|
            redis.set(old, "old")
            redis.set(new, "new")
          end

          report = JoobQ.migrate_keyspace!(queues: [] of String)

          report.skipped.should be_empty
          existing.call(keys.keys).should eq(0)
          keys.each_value { |new| redis.get(new).should eq("new") }
        ensure
          redis.del(keys.keys + keys.values)
        end
      end

      it "leaves a pair of keys of different types where they are, and lists the old one" do
        redis.set(Keys.queue(queue), "not a list")

        report = JoobQ.migrate_keyspace!(queues: [queue])

        report.skipped.should eq([queue])
        redis.get(Keys.queue(queue)).should eq("not a list")
        redis.llen(queue).should eq(2)
      end

      it "refuses while a process of the new namespace is live" do
        redis.zadd(Keys::PROCESSING_OWNERS, store.redis_now_ms, "newhost:7")

        expect_raises(KeyspaceMigrationError, /newhost:7/) { JoobQ.migrate_keyspace!(queues: [queue]) }

        redis.llen(queue).should eq(2)
      end
    end

    it "lets a worker claim and finish a migrated 0.6 job that has no format version" do
      name = "mig_run_#{Random::Secure.hex(3)}"
      old = JSON.parse(MigratedJob.new(name).to_json).as_h.reject("v").to_json
      redis.rpush(name, old)
      JoobQ.migrate_keyspace!(queues: [name]).renamed.should be >= 1
      MigratedJob::RAN.set(0)
      runner = Queue(MigratedJob).new(name, 1)
      JoobQ.queues[name] = runner
      begin
        runner.start

        eventually { MigratedJob::RAN.get == 1 && store.queue_size(name) == 0 }.should be_true
        eventually { redis.llen(Keys.processing(name, store.owner_id)) == 0 }.should be_true
      ensure
        runner.stop!
        JoobQ.queues.delete(name)
        redis.del(name, Keys.queue(name), Keys.processing(name, store.owner_id))
      end
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
