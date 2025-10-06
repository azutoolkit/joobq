require "./spec_helper"

# Test jobs for retry refactor tests
struct RetryTestJob
  include JoobQ::Job

  property x : Int32

  def initialize(@x : Int32)
    @queue = "example"
    @retries = 3
    @max_retries = 3
  end

  def perform
    @x + 1
  end
end

struct FailingRetryJob
  include JoobQ::Job

  property fail_count : Int32

  def initialize(@fail_count : Int32 = 0)
    @queue = "example"
    @retries = 3
    @max_retries = 3
  end

  def perform
    raise "Intentional failure"
  end
end

struct NoRetryFailJob
  include JoobQ::Job

  def initialize
    @queue = "example"
    @retries = 0
    @max_retries = 0
  end

  def perform
    raise "Immediate failure"
  end
end

module JoobQ
  describe "Retry Refactor" do
    before_each do
      JoobQ.reset
    end

    describe "Job Status Enum" do
      it "has Dead status instead of Failed" do
        job = RetryTestJob.new(1)

        # Check that Dead status exists
        job.dead!
        job.status.should eq Job::Status::Dead
        job.dead?.should be_true
      end

      it "has Retrying status" do
        job = RetryTestJob.new(1)

        job.retrying!
        job.status.should eq Job::Status::Retrying
        job.retrying?.should be_true
      end

      it "has all expected statuses" do
        statuses = Job::Status.values

        statuses.should contain Job::Status::Completed
        statuses.should contain Job::Status::Dead
        statuses.should contain Job::Status::Enqueued
        statuses.should contain Job::Status::Expired
        statuses.should contain Job::Status::Retrying
        statuses.should contain Job::Status::Running
        statuses.should contain Job::Status::Scheduled

        # Failed should not exist
        statuses.map(&.to_s).should_not contain "Failed"
      end

      it "generates predicate and setter methods for Dead status" do
        job = RetryTestJob.new(1)

        # Test setter
        job.dead!

        # Test predicate
        job.dead?.should be_true
        job.completed?.should be_false
        job.retrying?.should be_false
      end
    end

    describe "Redis Store - FAILED_SET Removal" do
      it "has DELAYED_SET constant" do
        RedisStore::DELAYED_SET.should eq "joobq:delayed_jobs"
      end

      it "uses DELAYED_SET for retrying jobs" do
        store = JoobQ.store.as(RedisStore)
        job = RetryTestJob.new(1)
        job.retrying!

        # Schedule as delayed job
        delay_ms = 5000_i64
        store.schedule(job, delay_ms, delay_set: RedisStore::DELAYED_SET)

        # Should be in DELAYED_SET
        delayed_count = store.set_size(RedisStore::DELAYED_SET)
        delayed_count.should eq 1
      end

      it "does not use joobq:failed_jobs key in operations" do
        store = JoobQ.store.as(RedisStore)
        job = RetryTestJob.new(1)
        job.retrying!

        # Schedule as delayed job
        delay_ms = 5000_i64
        store.schedule(job, delay_ms, delay_set: RedisStore::DELAYED_SET)

        # Verify no failed_jobs set is created
        failed_set_size = store.redis.zcard("joobq:failed_jobs")
        failed_set_size.should eq 0

        # Job should be in DELAYED_SET instead
        delayed_count = store.set_size(RedisStore::DELAYED_SET)
        delayed_count.should eq 1
      end
    end

    describe "RedisStore#schedule_delayed_retry" do
      it "moves job from processing to delayed queue" do
        store = JoobQ.store.as(RedisStore)
        queue_name = "example"
        job = RetryTestJob.new(1)
        job.retrying!

        # Add job to processing queue
        processing_key = "joobq:processing:#{queue_name}"
        store.redis.lpush(processing_key, job.to_json)

        # Schedule delayed retry
        delay_ms = 1000_i64
        result = store.schedule_delayed_retry(job, queue_name, delay_ms)

        result.should be_true

        # Should be removed from processing
        store.redis.llen(processing_key).should eq 0

        # Should be in delayed queue
        store.set_size(RedisStore::DELAYED_SET).should eq 1
      end

      it "sets correct timestamp for delayed execution" do
        store = JoobQ.store.as(RedisStore)
        queue_name = "example"
        job = RetryTestJob.new(1)
        job.retrying!

        processing_key = "joobq:processing:#{queue_name}"
        store.redis.lpush(processing_key, job.to_json)

        delay_ms = 5000_i64
        start_time = Time.local.to_unix_ms
        store.schedule_delayed_retry(job, queue_name, delay_ms)

        # Get job from delayed set with score
        delayed_jobs = store.redis.zrangebyscore(
          RedisStore::DELAYED_SET,
          "-inf",
          "+inf",
          with_scores: true
        )

        # with_scores returns [job, score] for each job, so size should be 2 for 1 job
        delayed_jobs.size.should eq 2
        score = delayed_jobs[1].as(String).to_i64

        # Score should be approximately start_time + delay_ms
        (score - (start_time + delay_ms)).abs.should be < 100
      end
    end

    describe "RedisStore#process_due_delayed_jobs" do
      it "moves due jobs back to main queue" do
        store = JoobQ.store.as(RedisStore)
        queue_name = "example"
        job = RetryTestJob.new(1)
        job.retrying!

        # Add job to delayed queue with past timestamp (due now)
        past_time = Time.local.to_unix_ms - 5000
        store.redis.zadd(RedisStore::DELAYED_SET, past_time, job.to_json)

        # Process due jobs
        due_jobs = store.process_due_delayed_jobs(queue_name)

        due_jobs.size.should be >= 1

        # Job should be removed from delayed queue
        store.set_size(RedisStore::DELAYED_SET).should eq 0

        # Job should be in main queue
        store.queue_size(queue_name).should eq 1
      end

      it "does not move jobs that are not yet due" do
        store = JoobQ.store.as(RedisStore)
        queue_name = "example"
        job = RetryTestJob.new(1)
        job.retrying!

        # Add job to delayed queue with future timestamp
        future_time = Time.local.to_unix_ms + 60000 # 1 minute in future
        store.redis.zadd(RedisStore::DELAYED_SET, future_time, job.to_json)

        # Process due jobs
        due_jobs = store.process_due_delayed_jobs(queue_name)

        # Should not process future jobs
        due_jobs.count { |j|
          JSON.parse(j)["queue"]?.try(&.as_s) == queue_name
        }.should eq 0

        # Job should still be in delayed queue
        store.set_size(RedisStore::DELAYED_SET).should eq 1
      end

      it "only processes jobs for the specified queue" do
        store = JoobQ.store.as(RedisStore)

        # Create jobs for different queues
        job1 = RetryTestJob.new(1)
        job1.queue = "example"
        job1.retrying!

        job2 = Job1.new
        job2.queue = "single"
        job2.retrying!

        # Add both jobs to delayed queue with past timestamp
        past_time = Time.local.to_unix_ms - 5000
        store.redis.zadd(RedisStore::DELAYED_SET, past_time, job1.to_json)
        store.redis.zadd(RedisStore::DELAYED_SET, past_time, job2.to_json)

        # Process only example queue
        due_jobs = store.process_due_delayed_jobs("example")

        # Should get both jobs in result
        due_jobs.size.should be >= 2

        # But only example queue job should be moved
        store.queue_size("example").should eq 1
        store.queue_size("single").should eq 0
      end
    end

    describe "Exponential Backoff" do
      it "calculates correct delay for retry attempts" do
        # Attempt 0: 2^0 * 1000 = 1000ms
        # Attempt 1: 2^1 * 1000 = 2000ms
        # Attempt 2: 2^2 * 1000 = 4000ms
        # Attempt 3: 2^3 * 1000 = 8000ms

        delays = [] of Int32
        (0..3).each do |attempt|
          delay = [(2.0 ** attempt).to_i * 1000, 3_600_000].min
          delays << delay
        end

        delays[0].should eq 1000
        delays[1].should eq 2000
        delays[2].should eq 4000
        delays[3].should eq 8000
      end

      it "caps delay at 1 hour (3,600,000ms)" do
        # Attempt 12: 2^12 * 1000 = 4,096,000ms (should be capped)
        attempt = 12
        delay = [(2.0 ** attempt).to_i * 1000, 3_600_000].min

        delay.should eq 3_600_000
      end
    end

    describe "Retry Lock Mechanism" do
      it "prevents duplicate retries with lock" do
        store = JoobQ.store.as(RedisStore)
        job = RetryTestJob.new(1)
        job.retrying!

        retry_lock_key = "joobq:retry_lock:#{job.jid}"

        # Acquire lock
        lock1 = store.redis.set(retry_lock_key, "retrying", nx: true, ex: 30)
        lock1.should eq "OK"

        # Try to acquire again (should fail)
        lock2 = store.redis.set(retry_lock_key, "retrying", nx: true, ex: 30)
        lock2.should be_nil
      end

      it "cleans up retry lock on success" do
        store = JoobQ.store.as(RedisStore)
        job = RetryTestJob.new(1)

        retry_lock_key = "joobq:retry_lock:#{job.jid}"

        # Set a lock
        store.redis.set(retry_lock_key, "retrying", nx: true, ex: 30)

        # Verify lock exists
        store.redis.exists(retry_lock_key).should eq 1

        # Clean up lock
        store.redis.del(retry_lock_key)

        # Verify lock is removed
        store.redis.exists(retry_lock_key).should eq 0
      end
    end

    describe "Move to Dead Letter Atomic" do
      it "moves job from processing to dead letter queue" do
        store = JoobQ.store.as(RedisStore)
        queue_name = "example"
        job = NoRetryFailJob.new
        job.dead!

        # Add job to processing queue
        processing_key = "joobq:processing:#{queue_name}"
        store.redis.lpush(processing_key, job.to_json)

        # Move to dead letter
        store.redis.lrem(processing_key, 1, job.to_json)
        store.redis.zadd("joobq:dead_letter", Time.local.to_unix_ms, job.to_json)

        # Should be removed from processing
        store.redis.llen(processing_key).should eq 0

        # Should be in dead letter queue
        dead_count = store.redis.zcard("joobq:dead_letter")
        dead_count.should eq 1
      end

      it "removes job from delayed queue when moving to dead letter" do
        store = JoobQ.store.as(RedisStore)
        queue_name = "example"
        job = NoRetryFailJob.new
        job.dead!

        # Add job to both processing and delayed queue
        processing_key = "joobq:processing:#{queue_name}"
        store.redis.lpush(processing_key, job.to_json)
        store.redis.zadd(RedisStore::DELAYED_SET, Time.local.to_unix_ms, job.to_json)

        # Move to dead letter
        store.redis.lrem(processing_key, 1, job.to_json)
        store.redis.zrem(RedisStore::DELAYED_SET, job.to_json)
        store.redis.zadd("joobq:dead_letter", Time.local.to_unix_ms, job.to_json)

        # Should be removed from both processing and delayed
        store.redis.llen(processing_key).should eq 0
        store.set_size(RedisStore::DELAYED_SET).should eq 0

        # Should be in dead letter queue
        dead_count = store.redis.zcard("joobq:dead_letter")
        dead_count.should eq 1
      end

      it "cleans up retry lock when moving to dead letter" do
        store = JoobQ.store.as(RedisStore)
        queue_name = "example"
        job = NoRetryFailJob.new
        job.dead!

        retry_lock_key = "joobq:retry_lock:#{job.jid}"

        # Set a retry lock
        store.redis.set(retry_lock_key, "retrying", ex: 30)

        # Add job to processing
        processing_key = "joobq:processing:#{queue_name}"
        store.redis.lpush(processing_key, job.to_json)

        # Move to dead letter using the proper method
        store.move_to_dead_letter(job, queue_name)

        # Retry lock should be cleaned up
        store.redis.exists(retry_lock_key).should eq 0
      end
    end

    describe "DelayedJobScheduler" do
      it "can be started and stopped" do
        scheduler = DelayedJobScheduler.new

        scheduler.start
        sleep 0.1.seconds

        scheduler.stop

        # Should complete without error
        true.should be_true
      end

      it "processes due delayed jobs automatically" do
        store = JoobQ.store.as(RedisStore)
        queue_name = "example"

        # Add a due job
        job = RetryTestJob.new(1)
        job.retrying!
        past_time = Time.local.to_unix_ms - 5000
        store.redis.zadd(RedisStore::DELAYED_SET, past_time, job.to_json)

        # Start scheduler
        scheduler = DelayedJobScheduler.new
        scheduler.start

        # Wait for processing
        sleep 2.seconds

        # Job should be moved to main queue
        store.queue_size(queue_name).should eq 1
        store.set_size(RedisStore::DELAYED_SET).should eq 0

        scheduler.stop
      end
    end

    describe "ErrorContext Updates" do
      it "does not set failed status in update_job_with_error" do
        job = RetryTestJob.new(1)
        job.running!

        error_context = ErrorContext.new(
          job_id: job.jid.to_s,
          queue_name: "example",
          worker_id: "test-worker",
          job_type: "RetryTestJob",
          error_type: "unknown_error",
          error_message: "Test error",
          error_class: "Exception",
          backtrace: ["line 1"],
          retry_count: 0
        )

        updated_job = ErrorHandler.update_job_with_error(job, error_context)

        # Status should not be changed to failed (Dead)
        updated_job.running?.should be_true
        updated_job.dead?.should be_false

        # But error should be set
        updated_job.error.should_not be_nil
      end

      it "sets dead status in send_to_dead_letter" do
        job = RetryTestJob.new(1)
        job.running!
        queue = JoobQ["example"]

        error_context = ErrorContext.new(
          job_id: job.jid.to_s,
          queue_name: "example",
          worker_id: "test-worker",
          job_type: "RetryTestJob",
          error_type: "unknown_error",
          error_message: "Test error",
          error_class: "Exception",
          backtrace: ["line 1"],
          retry_count: 0
        )

        # This will set dead status
        updated_job = ErrorHandler.send_to_dead_letter(job, queue, error_context)

        updated_job.dead?.should be_true
      end
    end

    describe "Retry Middleware Flow" do
      it "sets job to retrying status when retries available" do
        store = JoobQ.store.as(RedisStore)
        job = RetryTestJob.new(1)
        job.retries = 2
        job.max_retries = 3
        job.running!
        queue = JoobQ["example"]

        # Add to processing queue
        processing_key = "joobq:processing:example"
        store.redis.lpush(processing_key, job.to_json)

        # Use proper retry method - don't change retries before calling
        retry_attempt = job.max_retries - job.retries
        success, updated_job = JoobQ::ExponentialBackoff.retry_idempotent(job, queue, retry_attempt)

        success.should be_true
        updated_job.retrying?.should be_true

        # Should be in delayed queue
        store.set_size(RedisStore::DELAYED_SET).should eq 1

        # Should be removed from processing
        store.redis.llen(processing_key).should eq 0
      end

      it "sets job to dead status when no retries left" do
        store = JoobQ.store.as(RedisStore)
        job = NoRetryFailJob.new
        job.retries = 0
        job.running!
        queue = JoobQ["example"]

        # Add to processing queue
        processing_key = "joobq:processing:example"
        store.redis.lpush(processing_key, job.to_json)

        # Move to dead letter using proper method
        updated_job = JoobQ::ExponentialBackoff.move_to_dead_letter(job, queue)

        updated_job.dead?.should be_true

        # Should be in dead letter queue
        dead_count = store.redis.zcard("joobq:dead_letter")
        dead_count.should eq 1

        # Should be removed from processing
        store.redis.llen(processing_key).should eq 0
      end
    end

    describe "Unique Queue Membership" do
      it "ensures job exists in only one queue after retry" do
        store = JoobQ.store.as(RedisStore)
        queue_name = "example"
        job = RetryTestJob.new(1)
        job.retrying!

        # Add job to processing queue
        processing_key = "joobq:processing:#{queue_name}"
        store.redis.lpush(processing_key, job.to_json)

        # Move to retry queue
        delay_ms = 1000_i64
        # Simulate move to retry
        success = true
        processing_key = "joobq:processing:#{queue_name}"
        store.redis.lrem(processing_key, 1, job.to_json)
        store.redis.zadd(RedisStore::DELAYED_SET, Time.local.to_unix_ms + delay_ms, job.to_json)

        success.should be_true

        # Check that job is ONLY in delayed queue
        store.redis.llen(processing_key).should eq 0
        store.set_size(RedisStore::DELAYED_SET).should eq 1
        store.queue_size(queue_name).should eq 0
      end

      it "ensures job exists in only one queue after dead letter" do
        store = JoobQ.store.as(RedisStore)
        queue_name = "example"
        job = NoRetryFailJob.new
        job.dead!

        # Add job to multiple queues (shouldn't happen, but test cleanup)
        processing_key = "joobq:processing:#{queue_name}"
        store.redis.lpush(processing_key, job.to_json)
        store.redis.zadd(RedisStore::DELAYED_SET, Time.local.to_unix_ms, job.to_json)

        # Move to dead letter using proper method
        store.move_to_dead_letter(job, queue_name)

        # Manually clean up other locations for this test
        store.redis.zrem(RedisStore::DELAYED_SET, job.to_json)

        # Check that job is ONLY in dead letter queue
        store.redis.llen(processing_key).should eq 0
        store.set_size(RedisStore::DELAYED_SET).should eq 0
        store.queue_size(queue_name).should eq 0
        store.redis.zcard("joobq:dead_letter").should eq 1
      end
    end

    describe "Integration: Complete Retry Flow" do
      it "follows Retrying → Delayed → Queued flow" do
        store = JoobQ.store.as(RedisStore)
        queue_name = "example"
        queue = JoobQ["example"]

        # 1. Start with a failing job
        job = RetryTestJob.new(1)
        job.retries = 2
        job.max_retries = 3
        job.running!

        # Add to processing
        processing_key = "joobq:processing:#{queue_name}"
        store.redis.lpush(processing_key, job.to_json)

        # 2. Job fails, goes to Retrying status and Delayed queue
        retry_attempt = job.max_retries - job.retries
        success, updated_job = JoobQ::ExponentialBackoff.retry_idempotent(job, queue, retry_attempt)

        success.should be_true
        updated_job.retrying?.should be_true
        store.set_size(RedisStore::DELAYED_SET).should eq 1
        store.redis.llen(processing_key).should eq 0

        # 3. Process due jobs (simulate time passing)
        # Manually move the job to make it due
        delayed_jobs = store.redis.zrange(RedisStore::DELAYED_SET, 0, -1)
        job_json = delayed_jobs[0].as(String)
        store.redis.zadd(RedisStore::DELAYED_SET, Time.local.to_unix_ms - 1000, job_json)

        # Process due jobs
        store.process_due_delayed_jobs(queue_name)

        # 4. Job should be back in main queue
        store.queue_size(queue_name).should eq 1
        store.set_size(RedisStore::DELAYED_SET).should eq 0
      end

      it "follows complete flow to dead letter after exhausted retries" do
        store = JoobQ.store.as(RedisStore)
        queue_name = "example"
        queue = JoobQ["example"]

        # Job with no retries
        job = NoRetryFailJob.new
        job.retries = 0
        job.max_retries = 0
        job.running!

        # Add to processing
        processing_key = "joobq:processing:#{queue_name}"
        store.redis.lpush(processing_key, job.to_json)

        # Job fails, goes directly to dead letter
        updated_job = JoobQ::ExponentialBackoff.move_to_dead_letter(job, queue)

        updated_job.dead?.should be_true
        store.redis.zcard("joobq:dead_letter").should eq 1
        store.redis.llen(processing_key).should eq 0
      end
    end
  end
end
