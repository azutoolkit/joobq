require "./spec_helper"

module JoobQ
  # Helper method to verify job is in exactly one location
  def self.verify_single_location(store : RedisStore, queue_name : String,
                                   main : Int32 = 0, processing : Int32 = 0,
                                   delayed : Int32 = 0, dead : Int32 = 0)
    store.queue_size(queue_name).should eq main
    store.redis.llen("joobq:processing:#{queue_name}").should eq processing
    store.set_size(RedisStore::DELAYED_SET).should eq delayed
    store.redis.zcard("joobq:dead_letter").should eq dead

    # Verify total is exactly 1 (or 0 if all are 0)
    total = main + processing + delayed + dead
    (total == 0 || total == 1).should be_true
  end

  describe "Unique Queue Membership" do
    before_each do
      JoobQ.reset
    end

    describe "Job exists in only one location at a time" do
      it "job is only in main queue when first enqueued" do
        store = JoobQ.store.as(RedisStore)
        queue_name = "example"
        job = ExampleJob.new(1)

        # Enqueue job
        store.enqueue(job)

        # Verify it's ONLY in main queue
        store.queue_size(queue_name).should eq 1
        store.redis.llen("joobq:processing:#{queue_name}").should eq 0
        store.set_size(RedisStore::DELAYED_SET).should eq 0
        store.redis.zcard("joobq:dead_letter").should eq 0
      end

      it "job is only in processing queue when claimed by worker" do
        store = JoobQ.store.as(RedisStore)
        queue_name = "example"
        job = ExampleJob.new(1)

        # Enqueue and claim job
        store.enqueue(job)
        claimed_job = store.claim_job(queue_name, "worker-1", ExampleJob)

        # Verify it's ONLY in processing queue
        store.queue_size(queue_name).should eq 0
        store.redis.llen("joobq:processing:#{queue_name}").should eq 1
        store.set_size(RedisStore::DELAYED_SET).should eq 0
        store.redis.zcard("joobq:dead_letter").should eq 0
      end

      it "job is only in delayed queue after retry scheduling" do
        store = JoobQ.store.as(RedisStore)
        queue_name = "example"
        job = ExampleJob.new(1)
        job.retrying!

        # Add to processing first
        processing_key = "joobq:processing:#{queue_name}"
        store.redis.lpush(processing_key, job.to_json)

        # Move to retry (atomic)
        delay_ms = 1000_i64
        success = store.move_to_retry_atomic(job, queue_name, delay_ms)

        success.should be_true

        # Verify it's ONLY in delayed queue
        store.queue_size(queue_name).should eq 0
        store.redis.llen(processing_key).should eq 0
        store.set_size(RedisStore::DELAYED_SET).should eq 1
        store.redis.zcard("joobq:dead_letter").should eq 0
      end

      it "job is only in dead letter queue after moving from processing" do
        store = JoobQ.store.as(RedisStore)
        queue_name = "example"
        job = ExampleJob.new(1)
        job.dead!

        # Add to processing first
        processing_key = "joobq:processing:#{queue_name}"
        store.redis.lpush(processing_key, job.to_json)

        # Move to dead letter (atomic)
        store.move_to_dead_letter_atomic(job, queue_name)

        # Verify it's ONLY in dead letter queue
        store.queue_size(queue_name).should eq 0
        store.redis.llen(processing_key).should eq 0
        store.set_size(RedisStore::DELAYED_SET).should eq 0
        store.redis.zcard("joobq:dead_letter").should eq 1
      end

      it "job moves back to main queue from delayed queue" do
        store = JoobQ.store.as(RedisStore)
        queue_name = "example"
        job = ExampleJob.new(1)
        job.retrying!

        # Add to delayed queue with past timestamp
        past_time = Time.local.to_unix_ms - 5000
        store.redis.zadd(RedisStore::DELAYED_SET, past_time, job.to_json)

        # Process due jobs
        store.process_due_delayed_jobs(queue_name)

        # Verify it's ONLY in main queue
        store.queue_size(queue_name).should eq 1
        store.redis.llen("joobq:processing:#{queue_name}").should eq 0
        store.set_size(RedisStore::DELAYED_SET).should eq 0
        store.redis.zcard("joobq:dead_letter").should eq 0
      end
    end

    describe "Cleanup ensures single location (edge cases)" do
      it "removes job from all queues when moving to dead letter" do
        store = JoobQ.store.as(RedisStore)
        queue_name = "example"
        job = ExampleJob.new(1)
        job.dead!
        job_json = job.to_json

        # Artificially add job to MULTIPLE locations (shouldn't happen, but test cleanup)
        store.redis.lpush(queue_name, job_json)
        store.redis.lpush("joobq:processing:#{queue_name}", job_json)
        store.redis.zadd(RedisStore::DELAYED_SET, Time.local.to_unix_ms, job_json)

        # Verify job is in multiple places
        store.queue_size(queue_name).should eq 1
        store.redis.llen("joobq:processing:#{queue_name}").should eq 1
        store.set_size(RedisStore::DELAYED_SET).should eq 1

        # Move to dead letter (should clean up all locations)
        store.move_to_dead_letter_atomic(job, queue_name)

        # Verify it's ONLY in dead letter queue
        store.queue_size(queue_name).should eq 0
        store.redis.llen("joobq:processing:#{queue_name}").should eq 0
        store.set_size(RedisStore::DELAYED_SET).should eq 0
        store.redis.zcard("joobq:dead_letter").should eq 1

        # Verify the job in dead letter is correct
        dead_jobs = store.redis.zrange("joobq:dead_letter", 0, -1)
        dead_jobs.size.should eq 1
      end

      it "removes duplicate entries from processing queue" do
        store = JoobQ.store.as(RedisStore)
        queue_name = "example"
        job = ExampleJob.new(1)
        job_json = job.to_json
        processing_key = "joobq:processing:#{queue_name}"

        # Add job multiple times to processing (shouldn't happen, but test cleanup)
        3.times { store.redis.lpush(processing_key, job_json) }
        store.redis.llen(processing_key).should eq 3

        # Move to retry (should remove ALL occurrences)
        job.retrying!
        success = store.move_to_retry_atomic(job, queue_name, 1000_i64)

        success.should be_true

        # Verify ALL occurrences are removed
        store.redis.llen(processing_key).should eq 0
        store.set_size(RedisStore::DELAYED_SET).should eq 1
      end

      it "ensures no duplicates when scheduling delayed retry" do
        store = JoobQ.store.as(RedisStore)
        queue_name = "example"
        job = ExampleJob.new(1)
        job.retrying!
        job_json = job.to_json
        processing_key = "joobq:processing:#{queue_name}"

        # Add job to processing
        store.redis.lpush(processing_key, job_json)

        # Schedule delayed retry
        result = store.schedule_delayed_retry(job, queue_name, 1000_i64)
        result.should be_true

        # Verify no duplicates in any queue
        store.queue_size(queue_name).should eq 0
        store.redis.llen(processing_key).should eq 0
        store.set_size(RedisStore::DELAYED_SET).should eq 1
        store.redis.zcard("joobq:dead_letter").should eq 0

        # Verify only ONE entry in delayed queue
        delayed_jobs = store.redis.zrange(RedisStore::DELAYED_SET, 0, -1)
        delayed_jobs.size.should eq 1
      end
    end

    describe "Multiple jobs maintain unique locations" do
      it "multiple jobs in different queues don't interfere" do
        store = JoobQ.store.as(RedisStore)

        # Create 3 jobs in different states
        job1 = ExampleJob.new(1)
        job2 = ExampleJob.new(2)
        job3 = ExampleJob.new(3)

        # Job 1: In main queue
        store.enqueue(job1)

        # Job 2: In delayed queue
        job2.retrying!
        store.redis.zadd(RedisStore::DELAYED_SET, Time.local.to_unix_ms + 5000, job2.to_json)

        # Job 3: In dead letter
        job3.dead!
        store.redis.zadd("joobq:dead_letter", Time.local.to_unix_ms, job3.to_json)

        # Verify each job is in exactly one location
        # Job 1
        main_queue_jobs = store.redis.lrange("example", 0, -1)
        main_queue_jobs.any? { |j| j.as(String).includes?(job1.jid.to_s) }.should be_true

        # Job 2
        delayed_jobs = store.redis.zrange(RedisStore::DELAYED_SET, 0, -1)
        delayed_jobs.any? { |j| j.as(String).includes?(job2.jid.to_s) }.should be_true

        # Job 3
        dead_jobs = store.redis.zrange("joobq:dead_letter", 0, -1)
        dead_jobs.any? { |j| j.as(String).includes?(job3.jid.to_s) }.should be_true

        # Verify total unique locations
        store.queue_size("example").should eq 1
        store.set_size(RedisStore::DELAYED_SET).should eq 1
        store.redis.zcard("joobq:dead_letter").should eq 1
      end

      it "processing multiple jobs maintains uniqueness" do
        store = JoobQ.store.as(RedisStore)
        queue_name = "example"

        # Enqueue 5 jobs
        jobs = (1..5).map { |i| ExampleJob.new(i) }
        jobs.each { |job| store.enqueue(job) }

        store.queue_size(queue_name).should eq 5

        # Claim 3 jobs (move to processing)
        3.times { store.claim_job(queue_name, "worker-1", ExampleJob) }

        # Verify distribution
        store.queue_size(queue_name).should eq 2
        store.redis.llen("joobq:processing:#{queue_name}").should eq 3

        # Total should still be 5 unique jobs
        (store.queue_size(queue_name) + store.redis.llen("joobq:processing:#{queue_name}")).should eq 5
      end
    end

    describe "Retry lock prevents duplicate scheduling" do
      it "prevents duplicate retry scheduling with lock" do
        store = JoobQ.store.as(RedisStore)
        queue_name = "example"
        queue = JoobQ["example"]
        job = ExampleJob.new(1)
        job.retries = 2
        job.max_retries = 3

        # Add to processing
        processing_key = "joobq:processing:#{queue_name}"
        store.redis.lpush(processing_key, job.to_json)

        # First retry attempt (should succeed)
        retry_attempt = job.max_retries - job.retries
        original_json = job.to_json  # Capture before modifications
        job.retries -= 1
        success1, _ = ExponentialBackoff.retry_idempotent_atomic_with_json(job, queue, retry_attempt, original_json)
        success1.should be_true

        # Add job back to processing (simulate duplicate processing)
        store.redis.lpush(processing_key, job.to_json)

        # Second retry attempt (should fail due to lock)
        success2, _ = ExponentialBackoff.retry_idempotent_atomic_with_json(job, queue, retry_attempt, original_json)
        success2.should be_false

        # Verify job is in delayed queue only once
        store.set_size(RedisStore::DELAYED_SET).should eq 1

        # Verify lock exists
        retry_lock_key = "joobq:retry_lock:#{job.jid}"
        store.redis.exists(retry_lock_key).should eq 1
      end

      it "cleans up retry lock after successful completion" do
        store = JoobQ.store.as(RedisStore)
        queue = JoobQ["example"]
        job = ExampleJob.new(1)

        # Set a retry lock
        retry_lock_key = "joobq:retry_lock:#{job.jid}"
        store.redis.set(retry_lock_key, "retrying", ex: 30)
        store.redis.exists(retry_lock_key).should eq 1

        # Cleanup lock
        ExponentialBackoff.cleanup_retry_lock_atomic(job, queue)

        # Verify lock is removed
        store.redis.exists(retry_lock_key).should eq 0
      end
    end

    describe "Complete flow maintains uniqueness" do
      it "job moves through complete lifecycle uniquely: Enqueued -> Processing -> Retrying -> Delayed -> Enqueued -> Processing -> Dead" do
        store = JoobQ.store.as(RedisStore)
        queue_name = "example"
        queue = JoobQ["example"]
        job = ExampleJob.new(1)
        job.retries = 1
        job.max_retries = 1

        # Step 1: Enqueued
        store.enqueue(job)
        JoobQ.verify_single_location(store, queue_name, main: 1)

        # Step 2: Processing (claim job)
        claimed_job_json = store.claim_job(queue_name, "worker-1", ExampleJob)
        claimed_job_json.should_not be_nil
        JoobQ.verify_single_location(store, queue_name, processing: 1)

        # Step 3: Retrying (job fails, moves to delayed)
        claimed_job = ExampleJob.from_json(claimed_job_json.not_nil!)
        retry_attempt = claimed_job.max_retries - claimed_job.retries
        original_json = claimed_job.to_json  # Capture before modifications
        claimed_job.retries -= 1
        success, _ = ExponentialBackoff.retry_idempotent_atomic_with_json(claimed_job, queue, retry_attempt, original_json)
        success.should be_true
        JoobQ.verify_single_location(store, queue_name, delayed: 1)

        # Step 4: Back to Enqueued (process due jobs)
        # Make job due by updating its score
        delayed_jobs = store.redis.zrange(RedisStore::DELAYED_SET, 0, -1)
        job_json = delayed_jobs[0].as(String)
        store.redis.zadd(RedisStore::DELAYED_SET, Time.local.to_unix_ms - 1000, job_json)
        store.process_due_delayed_jobs(queue_name)
        JoobQ.verify_single_location(store, queue_name, main: 1)

        # Step 5: Processing again
        claimed_job_json2 = store.claim_job(queue_name, "worker-1", ExampleJob)
        claimed_job_json2.should_not be_nil
        JoobQ.verify_single_location(store, queue_name, processing: 1)

        # Step 6: Dead (no retries left)
        claimed_job2 = ExampleJob.from_json(claimed_job_json2.not_nil!)
        claimed_job2.retries = 0
        ExponentialBackoff.move_to_dead_letter_atomic(claimed_job2, queue)
        JoobQ.verify_single_location(store, queue_name, dead: 1)
      end
    end
  end
end

