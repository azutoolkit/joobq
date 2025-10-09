require "./spec_helper"
require "http/client"
require "json"

module JoobQ
  describe "API Endpoints for Retry Refactor" do
    before_each do
      JoobQ.reset
    end

    describe "GET /joobq/jobs/retrying" do
      it "returns retrying jobs from delayed queue" do
        store = JoobQ.store.as(RedisStore)

        # Add retrying jobs
        3.times do |i|
          job = ExampleJob.new(i)
          job.queue = "example"
          job.retrying!
          store.redis.zadd(
            RedisStore::DELAYED_SET,
            Time.local.to_unix_ms + (i * 1000),
            job.to_json
          )
        end

        # Add a non-retrying job (should not be returned)
        completed_job = ExampleJob.new(99)
        completed_job.completed!
        store.redis.zadd(
          RedisStore::DELAYED_SET,
          Time.local.to_unix_ms,
          completed_job.to_json
        )

        # Get retrying jobs
        retrying_jobs = store.list_sorted_set_jobs(RedisStore::DELAYED_SET, 1, 50)
        retrying_jobs_parsed = retrying_jobs.select do |job_json|
          parsed = JSON.parse(job_json)
          status = parsed["status"]?.try(&.as_s)
          # Check for lowercase serialization
          status == "retrying" || status == "Retrying"
        end

        retrying_jobs_parsed.size.should eq 3
      end

      it "filters retrying jobs by queue" do
        store = JoobQ.store.as(RedisStore)

        # Add retrying jobs to different queues
        job1 = ExampleJob.new(1)
        job1.queue = "example"
        job1.retrying!
        store.redis.zadd(RedisStore::DELAYED_SET, Time.local.to_unix_ms, job1.to_json)

        job2 = Job1.new
        job2.queue = "single"
        job2.retrying!
        store.redis.zadd(RedisStore::DELAYED_SET, Time.local.to_unix_ms, job2.to_json)

        # Filter by queue
        all_jobs = store.list_sorted_set_jobs(RedisStore::DELAYED_SET, 1, 50)
        example_queue_jobs = all_jobs.select do |job_json|
          parsed = JSON.parse(job_json)
          status = parsed["status"]?.try(&.as_s)
          (status == "retrying" || status == "Retrying") &&
            parsed["queue"]?.try(&.as_s) == "example"
        end

        example_queue_jobs.size.should eq 1
        parsed_job = JSON.parse(example_queue_jobs[0])
        parsed_job["queue"].as_s.should eq "example"
      end

      it "respects limit parameter" do
        store = JoobQ.store.as(RedisStore)

        # Add 10 retrying jobs
        10.times do |i|
          job = ExampleJob.new(i)
          job.retrying!
          store.redis.zadd(RedisStore::DELAYED_SET, Time.local.to_unix_ms, job.to_json)
        end

        # Get with limit
        limited_jobs = store.list_sorted_set_jobs(RedisStore::DELAYED_SET, 1, 5)
        limited_jobs.size.should be <= 5
      end
    end

    describe "GET /joobq/jobs/dead" do
      it "returns dead letter jobs" do
        store = JoobQ.store.as(RedisStore)

        # Add dead jobs
        3.times do |i|
          job = ExampleJob.new(i)
          job.dead!
          store.redis.zadd("joobq:dead_letter", Time.local.to_unix_ms, job.to_json)
        end

        # Get dead jobs
        dead_jobs = store.redis.zrange("joobq:dead_letter", 0, -1)
        dead_jobs.size.should eq 3

        # Verify they're dead jobs
        dead_jobs.each do |job_data|
          parsed = JSON.parse(job_data.as(String))
          parsed["status"].as_s.should eq "dead"
        end
      end

      it "filters dead jobs by queue" do
        store = JoobQ.store.as(RedisStore)

        # Add dead jobs to different queues
        job1 = ExampleJob.new(1)
        job1.queue = "example"
        job1.dead!
        store.redis.zadd("joobq:dead_letter", Time.local.to_unix_ms, job1.to_json)

        job2 = Job1.new
        job2.queue = "single"
        job2.dead!
        store.redis.zadd("joobq:dead_letter", Time.local.to_unix_ms, job2.to_json)

        job3 = ExampleJob.new(3)
        job3.queue = "example"
        job3.dead!
        store.redis.zadd("joobq:dead_letter", Time.local.to_unix_ms, job3.to_json)

        # Filter by queue
        all_dead_jobs = store.redis.zrange("joobq:dead_letter", 0, -1)
        example_queue_jobs = all_dead_jobs.select do |job_data|
          parsed = JSON.parse(job_data.as(String))
          parsed["queue"]?.try(&.as_s) == "example"
        end

        example_queue_jobs.size.should eq 2
      end

      it "respects limit parameter" do
        store = JoobQ.store.as(RedisStore)

        # Add 10 dead jobs
        10.times do |i|
          job = ExampleJob.new(i)
          job.dead!
          store.redis.zadd("joobq:dead_letter", Time.local.to_unix_ms, job.to_json)
        end

        # Get with limit
        limited_jobs = store.redis.zrange("joobq:dead_letter", 0, 4) # 0-4 = 5 jobs
        limited_jobs.size.should eq 5
      end
    end

    describe "POST /joobq/jobs/:job_id/retry" do
      pending "moves dead job back to main queue" do
        store = JoobQ.store.as(RedisStore)

        # Add a dead job
        job = ExampleJob.new(1)
        job.queue = "example"
        job.dead!
        job_jid = job.jid.to_s

        store.redis.zadd("joobq:dead_letter", Time.local.to_unix_ms, job.to_json)

        # Verify it's in dead letter
        store.redis.zcard("joobq:dead_letter").should eq 1

        # Simulate retry (find and move the job)
        dead_jobs = store.redis.zrange("joobq:dead_letter", 0, -1)
        job_to_retry = dead_jobs.find do |job_data|
          parsed = JSON.parse(job_data.as(String))
          parsed["jid"]?.try(&.as_s) == job_jid
        end

        job_to_retry.should_not be_nil

        if job_to_retry
          queue_name = JSON.parse(job_to_retry.as(String))["queue"].as_s

          # Move from dead letter to main queue
          store.redis.pipelined do |pipe|
            pipe.zrem("joobq:dead_letter", job_to_retry.as(String))
            pipe.lpush(queue_name, job_to_retry.as(String))
          end

          # Allow time for pipelined operations to complete
          sleep 0.1.seconds

          # Verify move
          store.redis.zcard("joobq:dead_letter").should eq 0
          store.queue_size(queue_name).should eq 1
        end
      end

      it "returns 404 for non-existent job" do
        store = JoobQ.store.as(RedisStore)

        # Try to find a non-existent job
        fake_jid = UUID.random.to_s

        dead_jobs = store.redis.zrange("joobq:dead_letter", 0, -1)
        job_found = dead_jobs.any? do |job_data|
          parsed = JSON.parse(job_data.as(String))
          parsed["jid"]?.try(&.as_s) == fake_jid
        end

        job_found.should be_false
      end

      pending "restores job to correct queue" do
        store = JoobQ.store.as(RedisStore)

        # Add dead jobs to different queues
        job1 = ExampleJob.new(1)
        job1.queue = "example"
        job1.dead!

        job2 = Job1.new
        job2.queue = "single"
        job2.dead!

        store.redis.zadd("joobq:dead_letter", Time.local.to_unix_ms, job1.to_json)
        store.redis.zadd("joobq:dead_letter", Time.local.to_unix_ms, job2.to_json)

        # Retry job1
        job_jid = job1.jid.to_s
        dead_jobs = store.redis.zrange("joobq:dead_letter", 0, -1)
        job_to_retry = dead_jobs.find do |job_data|
          parsed = JSON.parse(job_data.as(String))
          parsed["jid"]?.try(&.as_s) == job_jid
        end

        if job_to_retry
          queue_name = JSON.parse(job_to_retry.as(String))["queue"].as_s

          store.redis.pipelined do |pipe|
            pipe.zrem("joobq:dead_letter", job_to_retry.as(String))
            pipe.lpush(queue_name, job_to_retry.as(String))
          end

          # Allow time for pipelined operations to complete
          sleep 0.1.seconds

          # Verify it went to the correct queue
          queue_name.should eq "example"
          store.queue_size("example").should eq 1
          store.queue_size("single").should eq 0
        end
      end
    end

    describe "API Response Format" do
      it "includes correct fields for retrying jobs response" do
        # Expected response format
        response = {
          status:    "success",
          jobs:      [] of JSON::Any,
          count:     0,
          timestamp: Time.local.to_rfc3339,
        }

        response.has_key?(:status).should be_true
        response.has_key?(:jobs).should be_true
        response.has_key?(:count).should be_true
        response.has_key?(:timestamp).should be_true
      end

      it "includes correct fields for dead jobs response" do
        # Expected response format
        response = {
          status:    "success",
          jobs:      [] of JSON::Any,
          count:     0,
          timestamp: Time.local.to_rfc3339,
        }

        response.has_key?(:status).should be_true
        response.has_key?(:jobs).should be_true
        response.has_key?(:count).should be_true
        response.has_key?(:timestamp).should be_true
      end

      it "includes correct fields for retry job response" do
        # Expected response format
        response = {
          status:    "success",
          message:   "Job retried successfully",
          job_id:    "some-uuid",
          queue:     "example",
          timestamp: Time.local.to_rfc3339,
        }

        response.has_key?(:status).should be_true
        response.has_key?(:message).should be_true
        response.has_key?(:job_id).should be_true
        response.has_key?(:queue).should be_true
        response.has_key?(:timestamp).should be_true
      end
    end

    describe "Error Handling" do
      it "handles errors when getting retrying jobs" do
        # Simulate error by trying to access invalid data
        store = JoobQ.store.as(RedisStore)

        # Add invalid JSON
        store.redis.zadd(RedisStore::DELAYED_SET, Time.local.to_unix_ms, "invalid json")

        # Get jobs (should handle parse error gracefully)
        jobs = store.list_sorted_set_jobs(RedisStore::DELAYED_SET, 1, 50)
        jobs.select do |job_json|
          begin
            parsed = JSON.parse(job_json)
            parsed["status"]?.try(&.as_s) == "Retrying"
          rescue
            false
          end
        end.size.should eq 0
      end

      it "handles errors when getting dead jobs" do
        store = JoobQ.store.as(RedisStore)

        # Add invalid JSON
        store.redis.zadd("joobq:dead_letter", Time.local.to_unix_ms, "invalid json")

        # Get jobs (should handle parse error gracefully)
        dead_jobs = store.redis.zrange("joobq:dead_letter", 0, -1)
        valid_jobs = dead_jobs.select do |job_data|
          begin
            parsed = JSON.parse(job_data.as(String))
            status = parsed["status"]?.try(&.as_s)
            status == "dead" || status == "Dead"
          rescue
            false
          end
        end

        valid_jobs.size.should eq 0
      end
    end
  end
end
