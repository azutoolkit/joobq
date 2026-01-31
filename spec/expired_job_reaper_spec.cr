require "./spec_helper"

module JoobQ
  describe ExpiredJobReaper do
    before_each do
      JoobQ.reset
    end

    describe "#reap_once" do
      it "reaps expired jobs from main queue" do
        store = JoobQ.store.as(RedisStore)

        job = ExampleJob.new(1)
        job.expires = (Time.local - 1.hour).to_unix_ms
        store.enqueue(job)

        store.queue_size("example").should eq(1)

        reaper = ExpiredJobReaper.new(store: store)
        reaper.reap_once

        store.queue_size("example").should eq(0)
        store.redis.zcard("joobq:dead_letter").should be >= 1
      end

      it "does not reap non-expired jobs" do
        store = JoobQ.store.as(RedisStore)

        job = ExampleJob.new(1)
        job.expires = (Time.local + 1.hour).to_unix_ms
        store.enqueue(job)

        reaper = ExpiredJobReaper.new(store: store)
        reaper.reap_once

        store.queue_size("example").should eq(1)
      end

      it "reaps only expired jobs from a mixed queue" do
        store = JoobQ.store.as(RedisStore)

        expired_job = ExampleJob.new(1)
        expired_job.expires = (Time.local - 1.hour).to_unix_ms
        store.enqueue(expired_job)

        valid_job = ExampleJob.new(2)
        valid_job.expires = (Time.local + 1.hour).to_unix_ms
        store.enqueue(valid_job)

        reaper = ExpiredJobReaper.new(store: store)
        reaper.reap_once

        store.queue_size("example").should eq(1)
      end

      it "reaps expired jobs from processing queue" do
        store = JoobQ.store.as(RedisStore)

        job = ExampleJob.new(1)
        job.expires = (Time.local - 1.hour).to_unix_ms

        processing_key = "joobq:processing:example"
        store.redis.rpush(processing_key, job.to_json)

        store.redis.llen(processing_key).should eq(1)

        reaper = ExpiredJobReaper.new(store: store)
        reaper.reap_once

        store.redis.llen(processing_key).should eq(0)
        store.redis.zcard("joobq:dead_letter").should be >= 1
      end

      it "handles pagination with many expired jobs" do
        store = JoobQ.store.as(RedisStore)

        # Enqueue more than PAGE_SIZE (100) expired jobs
        150.times do |i|
          job = ExampleJob.new(i)
          job.expires = (Time.local - 1.hour).to_unix_ms
          store.enqueue(job)
        end

        store.queue_size("example").should eq(150)

        reaper = ExpiredJobReaper.new(store: store)
        reaper.reap_once

        store.queue_size("example").should eq(0)
      end

      it "increments stats counters" do
        store = JoobQ.store.as(RedisStore)

        job = ExampleJob.new(1)
        job.expires = (Time.local - 1.hour).to_unix_ms
        store.enqueue(job)

        reaper = ExpiredJobReaper.new(store: store)
        reaper.reap_once

        expired_count = store.redis.hget("joobq:stats:expired", "example")
        expired_count.should_not be_nil
        expired_count.should_not be_nil
        expired_count.as(String).to_i.should be >= 1
      end

      it "continues scanning other queues after error in one" do
        store = JoobQ.store.as(RedisStore)

        # Enqueue an expired job in the "single" queue
        job = Job1.new
        job.expires = (Time.local - 1.hour).to_unix_ms
        store.enqueue(job)

        store.queue_size("single").should eq(1)

        reaper = ExpiredJobReaper.new(store: store)
        reaper.reap_once

        # The reaper should still process other queues even if one has issues
        store.queue_size("single").should eq(0)
      end
    end

    describe "#start and #stop" do
      it "starts and stops the reaper fiber" do
        store = JoobQ.store.as(RedisStore)
        reaper = ExpiredJobReaper.new(store: store, interval: 1.second)

        reaper.start
        sleep 0.1.seconds

        reaper.stop
        # Should not raise
      end

      it "is idempotent on double start" do
        store = JoobQ.store.as(RedisStore)
        reaper = ExpiredJobReaper.new(store: store, interval: 1.second)

        reaper.start
        reaper.start # should be no-op

        reaper.stop
      end

      it "is idempotent on double stop" do
        store = JoobQ.store.as(RedisStore)
        reaper = ExpiredJobReaper.new(store: store, interval: 1.second)

        reaper.start
        reaper.stop
        reaper.stop # should be no-op
      end
    end

    describe "scan_limit" do
      it "respects the scan limit" do
        store = JoobQ.store.as(RedisStore)

        # Enqueue 200 expired jobs
        200.times do |i|
          job = ExampleJob.new(i)
          job.expires = (Time.local - 1.hour).to_unix_ms
          store.enqueue(job)
        end

        # Set scan limit to 100 — should only scan first 100 entries
        reaper = ExpiredJobReaper.new(store: store, scan_limit: 100)
        reaper.reap_once

        # Some jobs should remain since scan limit was hit
        store.queue_size("example").should eq(100)
      end
    end
  end
end
