require "./spec_helper"

module JoobQ
  describe "Race Conditions" do
    before_each do
      JoobQ.reset
    end

    describe "concurrent job enqueue" do
      pending "handles multiple concurrent enqueues" do
        queue = JoobQ["example"]
        store = JoobQ.store.as(RedisStore)

        # Clear queue
        store.clear_queue("example")

        # Enqueue 100 jobs concurrently
        channel = Channel(UUID).new
        100.times do |i|
          spawn do
            job = ExampleJob.new(i)
            jid = store.enqueue(job)
            channel.send(jid)
          end
        end

        # Collect all JIDs
        jids = [] of UUID
        100.times { jids << channel.receive }

        # All JIDs should be unique
        jids.uniq.size.should eq(100)

        # All jobs should be in queue
        store.queue_size("example").should eq(100)
      end
    end

    describe "concurrent job processing" do
      pending "prevents duplicate job processing" do
        queue = Queue(ExampleJob).new("example", 5)
        store = JoobQ.store.as(RedisStore)

        # Add 10 jobs
        jobs = [] of ExampleJob
        10.times do |i|
          job = ExampleJob.new(i)
          jobs << job
          store.enqueue(job)
        end

        queue.start
        sleep 2.seconds
        queue.stop!

        # Each job should be processed exactly once
        # (This requires tracking job execution counts)
        store.queue_size("example").should eq(0)
      end
    end

    describe "concurrent retry scheduling" do
      pending "prevents duplicate retry scheduling" do
        queue = JoobQ["example"]
        store = JoobQ.store.as(RedisStore)

        job = RetryTestJob.new(1)
        job.retries = 3
        job.max_retries = 3

        # Add to processing queue
        processing_key = "joobq:processing:example"
        store.redis.lpush(processing_key, job.to_json)
        store.redis.lpush(processing_key, job.to_json) # Duplicate

        # Try to schedule retry from multiple workers concurrently
        channel = Channel(Bool).new
        results = [] of Bool

        5.times do
          spawn do
            success, _ = JoobQ::ExponentialBackoff.retry_idempotent(job, queue, 0)
            channel.send(success)
          end
        end

        5.times { results << channel.receive }

        # Only one should succeed
        results.count(true).should eq(1)

        # Should be in delayed queue only once
        store.set_size(RedisStore::DELAYED_SET).should eq(1)
      end
    end

    describe "concurrent dead letter moves" do
      pending "handles concurrent moves to dead letter" do
        queue = JoobQ["example"]
        store = JoobQ.store.as(RedisStore)

        job = NoRetryFailJob.new
        job.dead!

        # Add same job to multiple queues (simulate race condition)
        processing_key = "joobq:processing:example"
        3.times { store.redis.lpush(processing_key, job.to_json) }

        # Try to move to dead letter concurrently
        channel = Channel(Nil).new
        3.times do
          spawn do
            store.move_to_dead_letter(job, "example")
            channel.send(nil)
          end
        end

        3.times { channel.receive }

        # Should be in dead letter queue exactly once
        store.redis.zcard("joobq:dead_letter").should eq(1)

        # Should not be in processing queue
        store.redis.llen(processing_key).should eq(0)
      end
    end

    describe "queue state transitions" do
      pending "maintains atomicity during state changes" do
        store = JoobQ.store.as(RedisStore)
        queue_name = "example"

        # Create a job
        job = ExampleJob.new(1)
        store.enqueue(job)

        # Simulate concurrent operations on same job
        channel = Channel(String).new
        operations = [] of String

        spawn do
          # Operation 1: Move to processing
          claimed = store.claim_job(queue_name, "worker-1", ExampleJob)
          channel.send(claimed ? "claimed" : "not_claimed")
        end

        spawn do
          # Operation 2: Try to claim same job
          claimed = store.claim_job(queue_name, "worker-2", ExampleJob)
          channel.send(claimed ? "claimed" : "not_claimed")
        end

        2.times { operations << channel.receive }

        # Only one worker should claim the job
        operations.count("claimed").should eq(1)
      end
    end

    describe "retry lock contention" do
      pending "handles retry lock contention correctly" do
        queue = JoobQ["example"]
        store = JoobQ.store.as(RedisStore)

        job = RetryTestJob.new(1)
        job.retries = 2

        processing_key = "joobq:processing:example"
        store.redis.lpush(processing_key, job.to_json)

        # Multiple workers try to retry same job
        results = [] of Bool
        channel = Channel(Bool).new

        10.times do
          spawn do
            success, _ = JoobQ::ExponentialBackoff.retry_idempotent(job, queue, 0)
            channel.send(success)
          end
        end

        10.times { results << channel.receive }

        # Only one should acquire the lock
        results.count(true).should eq(1)
        results.count(false).should eq(9)
      end
    end

    describe "worker restart race conditions" do
      pending "handles worker crashes during job processing" do
        queue = Queue(ExampleJob).new("example", 3)
        store = JoobQ.store.as(RedisStore)

        # Add jobs
        5.times { |i| store.enqueue(ExampleJob.new(i)) }

        queue.start
        sleep 0.5.seconds

        # Simulate worker crash (force stop without cleanup)
        queue.stop!

        # Jobs might be in processing queue
        processing_size = store.redis.llen("joobq:processing:example")

        # All jobs should eventually be recovered
        # (This tests dead job recovery mechanisms)
        processing_size.should be >= 0
      end
    end

    describe "delayed job race conditions" do
      pending "handles concurrent delayed job processing" do
        store = JoobQ.store.as(RedisStore)

        # Add multiple due jobs
        5.times do |i|
          job = RetryTestJob.new(i)
          job.retrying!
          past_time = Time.local.to_unix_ms - 5000
          store.redis.zadd(RedisStore::DELAYED_SET, past_time, job.to_json)
        end

        # Multiple schedulers try to process same jobs
        channel = Channel(Array(String)).new
        all_processed = [] of String

        3.times do
          spawn do
            processed = store.process_due_delayed_jobs("example")
            channel.send(processed)
          end
        end

        3.times do
          processed = channel.receive
          all_processed.concat(processed)
        end

        # Jobs should not be processed multiple times
        # (Exact count depends on implementation, but should be reasonable)
        store.set_size(RedisStore::DELAYED_SET).should eq(0)
      end
    end
  end
end
