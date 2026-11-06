require "./spec_helper"

# Queue order and crash recovery at the store level. Producers RPUSH to the tail; a process claims from the head into
# its own per-process list `joobq:processing:<queue>:<owner>` and publishes a liveness heartbeat. Recovery returns a
# process's jobs to the HEAD of the queue only once that process's heartbeat has lapsed, so a live process's in-flight
# jobs are never moved and never run twice.
module JoobQ
  describe "FIFO queue order and per-process recovery" do
    store = JoobQ.store.as(RedisStore)
    redis = store.redis
    name = "fifo_spec"
    self_owner = store.owner_id

    owned = ->(owner : String) { "joobq:processing:#{name}:#{owner}" }
    legacy = "joobq:processing:#{name}"
    live = ->(owner : String) { redis.zadd(RedisStore::OWNERS, Time.utc.to_unix_ms, owner) }
    dead = ->(owner : String) { redis.zrem(RedisStore::OWNERS, owner) }
    # A worker claims onto the HEAD of its processing list; seed the same layout for a given claim order.
    seed_claims = ->(owner : String, jobs : Array(String)) { jobs.each { |job| redis.lpush(owned.call(owner), job) } }

    before_each do
      redis.del(name, legacy, owned.call(self_owner), owned.call("host:1"), owned.call("host:2"))
      ["#{self_owner}", "host:1", "host:2"].each { |o| redis.zrem(RedisStore::OWNERS, o) }
    end
    after_each do
      redis.del(name, legacy, owned.call(self_owner), owned.call("host:1"), owned.call("host:2"))
      ["#{self_owner}", "host:1", "host:2"].each { |o| redis.zrem(RedisStore::OWNERS, o) }
    end

    it "probes the server for LMOVE (Redis 6.2+) and accepts this one" do
      store.ensure_list_move_support!
      store.ensure_list_move_support!
      redis.exists("joobq:lmove-probe").should eq(0)
    end

    describe "claiming" do
      it "claims the oldest job first into this process's own list" do
        redis.rpush(name, "A", "B", "C")

        store.claim_job(name, "w1", Job1).should eq("A")
        redis.lrange(name, 0, -1).should eq(["B", "C"])
        redis.lrange(owned.call(self_owner), 0, -1).should eq(["A"])
        redis.exists(legacy).should eq(0) # 0.6 never claims into the shared list
      end

      it "claims a batch from the head, oldest first, and leaves the newer jobs queued" do
        redis.rpush(name, "A", "B", "C", "D", "E")

        store.claim_jobs_batch(name, "w1", Job1, 3).should eq(["A", "B", "C"])
        redis.lrange(name, 0, -1).should eq(["D", "E"])
        redis.llen(owned.call(self_owner)).should eq(3)
      end

      it "lists the next job to run first" do
        redis.rpush(name, "A", "B", "C")
        store.list_jobs(name).first.should eq("A")
        store.claim_job(name, "w1", Job1).should eq("A")
      end
    end

    describe "#recover_orphaned_processing" do
      it "returns a dead process's jobs to the head of the queue, in claim order, and deletes its list" do
        redis.rpush(name, "W1", "W2")               # already waiting
        seed_claims.call("host:1", ["A", "B", "C"]) # host:1 claimed A, then B, then C
        dead.call("host:1")

        store.recover_orphaned_processing(name).should eq(3)
        redis.lrange(name, 0, -1).should eq(["A", "B", "C", "W1", "W2"])
        redis.exists(owned.call("host:1")).should eq(0)
      end

      it "never moves a live process's in-flight jobs" do
        seed_claims.call("host:1", ["L1", "L2"])
        live.call("host:1")

        store.recover_orphaned_processing(name).should eq(0)
        redis.lrange(owned.call("host:1"), 0, -1).should eq(["L2", "L1"]) # untouched (head is newest claim)
        redis.llen(name).should eq(0)
      end

      it "recovers a dead process while leaving a live one alone, with no duplication or loss (crash + restart)" do
        redis.rpush(name, "WAIT")
        seed_claims.call("host:1", ["LIVE"]) # a worker still running
        live.call("host:1")
        seed_claims.call("host:2", ["DEAD"]) # a crashed worker
        dead.call("host:2")

        store.recover_orphaned_processing(name).should eq(1)

        # DEAD ran once: now at the head of the queue, gone from processing; LIVE untouched.
        redis.lrange(name, 0, -1).should eq(["DEAD", "WAIT"])
        redis.exists(owned.call("host:2")).should eq(0)
        redis.lrange(owned.call("host:1"), 0, -1).should eq(["LIVE"])

        # No copy of any job exists in more than one place.
        everywhere = (redis.lrange(name, 0, -1) + redis.lrange(owned.call("host:1"), 0, -1) + redis.lrange(owned.call("host:2"), 0, -1)).map(&.as(String))
        everywhere.sort.should eq(["DEAD", "LIVE", "WAIT"])
      end

      it "drains this process's own leftover list only when asked (restart), never from a live reaper pass" do
        seed_claims.call(self_owner, ["X", "Y"])
        live.call(self_owner)

        store.recover_orphaned_processing(name, include_self: false).should eq(0) # a live reaper pass
        store.recover_orphaned_processing(name, include_self: true).should eq(2)  # a restart of this process
        redis.lrange(name, 0, -1).should eq(["X", "Y"])
      end

      it "migrates the legacy shared list only when no other process is live" do
        redis.lpush(legacy, "OLD1"); redis.lpush(legacy, "OLD2") # a 0.5 worker claimed OLD1 then OLD2 (BRPOPLPUSH pushes to the head)
        live.call("host:9")                                      # another process still live

        store.recover_orphaned_processing(name).should eq(0) # held back while another owner is live
        dead.call("host:9")
        store.recover_orphaned_processing(name).should eq(2)
        redis.lrange(name, 0, -1).should eq(["OLD1", "OLD2"])
      end
    end

    describe "#requeue_many_from_processing (shutdown)" do
      it "puts abandoned jobs at the head of their queue so they run next, keeping claim order" do
        redis.rpush(name, "X", "Y")
        seed_claims.call(self_owner, ["A", "B"]) # this process claimed A then B

        store.requeue_many_from_processing([{name, "A"}, {name, "B"}]).should eq(2)
        redis.lrange(name, 0, -1).should eq(["A", "B", "X", "Y"])
        store.claim_job(name, "w1", Job1).should eq("A")
      end

      it "keeps claim order across script batches" do
        jobs = (0...(RedisStore::REQUEUE_BATCH + 50)).map { |i| "job-#{i}" }
        jobs.reverse_each { |job| redis.lpush(owned.call(self_owner), job) } # claimed job-0 first
        redis.rpush(name, "newer")

        store.requeue_many_from_processing(jobs.map { |job| {name, job} }).should eq(jobs.size)
        redis.lrange(name, 0, -1).should eq(jobs + ["newer"])
      end

      it "also requeues a job sitting in the legacy shared list" do
        redis.lpush(legacy, "L")
        store.requeue_many_from_processing([{name, "L"}]).should eq(1)
        redis.lrange(name, 0, -1).should eq(["L"])
      end
    end

    it "puts a job bounced for missing keys at the tail (requeue_from_processing)" do
      redis.rpush(name, "X")
      redis.lpush(owned.call(self_owner), "A")

      store.requeue_from_processing("A", name).should be_true
      redis.lrange(name, 0, -1).should eq(["X", "A"])
    end
  end
end
