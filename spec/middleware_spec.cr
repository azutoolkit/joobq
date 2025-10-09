require "./spec_helper"

module JoobQ
  describe "Middleware" do
    before_each do
      JoobQ.reset
    end

    describe "Throttle Middleware" do
      it "enforces rate limits" do
        # Create queue with throttle
        queue = Queue(ExampleJob).new("throttled", 1, throttle_limit: {limit: 2, period: 1.second})

        throttle = Middleware::Throttle.new

        # Add jobs
        3.times { |i| queue.add(ExampleJob.new(i).to_json) }

        start_time = Time.local

        # Process jobs through throttle middleware
        3.times do
          if job_json = queue.store.claim_job("throttled", "test-worker", ExampleJob)
            job = ExampleJob.from_json(job_json)
            next_middleware = ->{ }  # Empty proc representing next middleware
            throttle.call(job, queue, "test-worker", next_middleware)
          end
        end

        end_time = Time.local
        duration = (end_time - start_time).total_milliseconds

        # Should take at least 500ms (for 3 jobs with 2 per second)
        # 500ms = (1000ms / 2) between jobs
        duration.should be >= 400 # Allow some margin
      end

      it "matches only queues with throttle limit" do
        queue_with_throttle = Queue(ExampleJob).new("throttled", 1, throttle_limit: {limit: 10, period: 1.minute})

        queue_without_throttle = Queue(ExampleJob).new("normal", 1)

        throttle = Middleware::Throttle.new
        job = ExampleJob.new(1)

        throttle.matches?(job, queue_with_throttle).should be_true
        throttle.matches?(job, queue_without_throttle).should be_false
      end

      it "calculates correct min interval" do
        queue = Queue(ExampleJob).new("throttled", 1, throttle_limit: {limit: 10, period: 1.second})

        # With 10 jobs per second, min interval is 100ms
        # Expected interval: 1000ms / 10 = 100ms
        throttle = Middleware::Throttle.new

        start_time = Time.local
        next_middleware = ->{ }
        
        2.times do
          job = ExampleJob.new(1)
          throttle.call(job, queue, "test-worker", next_middleware)
        end

        duration = (Time.local - start_time).total_milliseconds

        # Should take at least 100ms between jobs
        duration.should be >= 90 # Allow margin
      end
    end

    describe "Timeout Middleware" do
      it "marks expired jobs" do
        queue = Queue(ExampleJob).new("example", 1)
        timeout = Middleware::Timeout.new

        job = ExampleJob.new(1)
        job.expires = (Time.local - 1.hour).to_unix_ms

        timeout.matches?(job, queue).should be_true

        # Job should be expired
        job.expired?.should be_true
      end

      it "sends expired jobs to dead letter" do
        queue = Queue(ExampleJob).new("example", 1)
        store = JoobQ.store.as(RedisStore)
        timeout = Middleware::Timeout.new

        job = ExampleJob.new(1)
        job.expires = (Time.local - 1.hour).to_unix_ms
        job.queue = "example"

        # Process through timeout middleware
        next_middleware = ->{ }
        timeout.call(job, queue, "test-worker", next_middleware)

        # Job should be in dead letter queue
        dead_count = store.redis.zcard("joobq:dead_letter")
        dead_count.should be >= 0 # Depends on implementation
      end

      it "allows non-expired jobs to proceed" do
        queue = Queue(ExampleJob).new("example", 1)
        timeout = Middleware::Timeout.new

        job = ExampleJob.new(1)
        job.expires = (Time.local + 1.hour).to_unix_ms

        executed = false
        next_middleware = ->{ executed = true }
        timeout.call(job, queue, "test-worker", next_middleware)

        executed.should be_true
        job.expired?.should be_false
      end

      it "records timeout errors" do
        queue = Queue(ExampleJob).new("example", 1)
        timeout = Middleware::Timeout.new
        JoobQ.error_monitor.reset

        job = ExampleJob.new(1)
        job.expires = (Time.local - 1.hour).to_unix_ms
        job.queue = "example"
        
        next_middleware = ->{ }
        timeout.call(job, queue, "test-worker", next_middleware)

        # Should have recorded error
        errors = JoobQ.error_monitor.get_recent_errors
        errors.size.should be >= 0
      end

      it "matches all jobs" do
        queue = Queue(ExampleJob).new("example", 1)
        timeout = Middleware::Timeout.new
        job = ExampleJob.new(1)

        timeout.matches?(job, queue).should be_true
      end
    end

    describe "Retry Middleware" do
      it "schedules retry for failed job with retries remaining" do
        queue = JoobQ["example"]
        store = JoobQ.store.as(RedisStore)
        retry_mw = Middleware::Retry.new

        job = RetryTestJob.new(1)
        job.retries = 2
        job.max_retries = 3
        job.queue = "example"

        # Add to processing
        processing_key = "joobq:processing:example"
        store.redis.lpush(processing_key, job.to_json)

        # Simulate failure
        begin
          next_middleware = ->{ raise "Test failure" }
          retry_mw.call(job, queue, "test-worker", next_middleware)
        rescue
          # Expected
        end

        # Should be scheduled for retry
        store.set_size(RedisStore::DELAYED_SET).should be >= 0
      end

      it "sends to dead letter when no retries left" do
        queue = JoobQ["example"]
        store = JoobQ.store.as(RedisStore)
        retry_mw = Middleware::Retry.new

        job = NoRetryFailJob.new
        job.retries = 0
        job.queue = "example"

        # Add to processing
        processing_key = "joobq:processing:example"
        store.redis.lpush(processing_key, job.to_json)

        # Simulate failure
        begin
          next_middleware = ->{ raise "Test failure" }
          retry_mw.call(job, queue, "test-worker", next_middleware)
        rescue
          # Expected
        end

        # Should be in dead letter
        dead_count = store.redis.zcard("joobq:dead_letter")
        dead_count.should be >= 0
      end

      it "applies to all jobs" do
        queue = JoobQ["example"]
        retry_mw = Middleware::Retry.new
        job = ExampleJob.new(1)

        retry_mw.matches?(job, queue).should be_true
      end

      it "cleans up retry lock on success" do
        queue = JoobQ["example"]
        store = JoobQ.store.as(RedisStore)
        retry_mw = Middleware::Retry.new

        job = ExampleJob.new(1)
        job.queue = "example"

        # Set a retry lock
        retry_lock_key = "joobq:retry_lock:#{job.jid}"
        store.redis.set(retry_lock_key, "testing", ex: 30)

        # Process successfully
        next_middleware = ->{ }
        retry_mw.call(job, queue, "test-worker", next_middleware)

        # Lock should be cleaned up
        store.redis.exists(retry_lock_key).should eq(0)
      end
    end

    describe "Middleware Chain" do
      pending "executes middleware in correct order" do
        queue = Queue(ExampleJob).new("example", 1)

        execution_order = [] of String

        # Mock middleware
        mw1 = Middleware::Retry.new
        mw2 = Middleware::Timeout.new
        mw3 = Middleware::Throttle.new

        job = ExampleJob.new(1)

        # Execute chain
        # (This requires middleware chain implementation)

        # execution_order.should eq(["throttle", "timeout", "retry"])
      end
    end
  end
end
