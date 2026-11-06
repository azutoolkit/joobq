require "./spec_helper"

# Queue order at the store level: producers RPUSH to the tail, workers claim from the head, and every way a claimed
# job goes back (crash recovery at start, shutdown requeue) puts it at the head, so it runs before newer work.
module JoobQ
  describe "FIFO queue order" do
    store = JoobQ.store.as(RedisStore)
    redis = store.redis
    name = "fifo_spec"
    processing = "joobq:processing:#{name}"

    before_each { redis.del(name, processing) }
    after_each { redis.del(name, processing) }

    it "claims the oldest job first" do
      redis.rpush(name, "A", "B", "C")

      store.claim_job(name, "w1", Job1).should eq("A")
      redis.lrange(name, 0, -1).should eq(["B", "C"])
      redis.lrange(processing, 0, -1).should eq(["A"])
    end

    it "claims a batch from the head, oldest first, and leaves the newer jobs queued" do
      redis.rpush(name, "A", "B", "C", "D", "E")

      store.claim_jobs_batch(name, "w1", Job1, 3).should eq(["A", "B", "C"])
      redis.lrange(name, 0, -1).should eq(["D", "E"])
      redis.llen(processing).should eq(3)
    end

    it "lists the next job to run first" do
      redis.rpush(name, "A", "B", "C")

      next_listed = store.list_jobs(name).first
      store.claim_job(name, "w1", Job1).should eq(next_listed)
    end

    it "probes the server for LMOVE (Redis 6.2+) and accepts this one" do
      store.ensure_list_move_support!
      store.ensure_list_move_support!
      redis.exists("joobq:lmove-probe").should eq(0)
    end

    describe "#move_job_back_to_queue" do
      it "returns every stranded job to the head of the queue, in the order they were claimed" do
        redis.rpush(name, "A", "B", "C", "D", "E")
        store.claim_jobs_batch(name, "w1", Job1, 2)
        store.claim_job(name, "w2", Job1)

        store.recover_processing(name).should eq(3)
        redis.lrange(name, 0, -1).should eq(["A", "B", "C", "D", "E"])
        redis.llen(processing).should eq(0)
      end

      it "recovers the processing layout an older (pre-FIFO) worker leaves behind in the same order" do
        # BRPOPLPUSH and RPOPLPUSH also push each claimed job onto the head of the processing list
        redis.lpush(processing, "A")
        redis.lpush(processing, "B")
        redis.lpush(processing, "C")
        redis.rpush(name, "D")

        store.move_job_back_to_queue(name).should be_true
        redis.lrange(name, 0, -1).should eq(["A", "B", "C", "D"])
        redis.llen(processing).should eq(0)
      end

      it "returns at once when nothing is stranded" do
        started = Time.instant
        store.recover_processing(name).should eq(0)
        store.move_job_back_to_queue(name).should be_false
        # the old BRPOPLPUSH waited BLOCKING_TIMEOUT (500 ms) on an empty list; the bound leaves room for a slow runner
        (Time.instant - started).should be < 450.milliseconds
        redis.llen(name).should eq(0)
      end
    end

    describe "#requeue_many_from_processing (shutdown)" do
      it "puts abandoned jobs at the head of their queue so they run next, keeping their order" do
        redis.rpush(name, "X", "Y")
        redis.lpush(processing, "A")
        redis.lpush(processing, "B")

        store.requeue_many_from_processing([{name, "A"}, {name, "B"}]).should eq(2)
        redis.lrange(name, 0, -1).should eq(["A", "B", "X", "Y"])
        store.claim_job(name, "w1", Job1).should eq("A")
      end

      it "keeps the order across script batches" do
        jobs = (0...(RedisStore::REQUEUE_BATCH + 50)).map { |i| "job-#{i}" }
        jobs.each { |job| redis.lpush(processing, job) }
        redis.rpush(name, "newer")

        store.requeue_many_from_processing(jobs.map { |job| {name, job} }).should eq(jobs.size)
        redis.lrange(name, 0, -1).should eq(jobs + ["newer"])
      end
    end

    it "puts a job bounced for missing keys at the tail (requeue_from_processing)" do
      redis.rpush(name, "X")
      redis.lpush(processing, "A")

      store.requeue_from_processing("A", name).should be_true
      redis.lrange(name, 0, -1).should eq(["X", "A"])
    end
  end
end
