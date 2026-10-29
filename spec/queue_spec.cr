require "./spec_helper"

module JoobQ
  describe Queue do
    job = ExampleJob.new 1
    queue = JoobQ["example"]

    before_each do
      JoobQ.reset
    end

    describe "#stop!" do
      it "stops all workers" do
        single_queue = Queue(Job1).new("single", 10)

        single_queue.start
        sleep 1.seconds

        single_queue.running?.should be_true
        single_queue.stop!

        single_queue.running?.should be_false
        single_queue.clear
      end
    end

    describe "#start" do
      it "reprocesses in-flight jobs once: starting a running queue must not requeue what a worker is processing" do
        name = "start_guard"
        redis = JoobQ.store.as(RedisStore).redis
        [name, "joobq:processing:#{name}"].each { |key| redis.del(key) }
        queue = Queue(Job1).new(name, 0) # no workers, so nothing consumes what the specs push
        redis.rpush("joobq:processing:#{name}", %({"jid":"a"}))

        queue.start
        redis.llen(name).should eq(1) # the first start puts the stranded job back

        redis.rpush("joobq:processing:#{name}", %({"jid":"b"})) # a job a worker is processing right now
        queue.start
        redis.llen(name).should eq(1) # a second start leaves it alone
        redis.llen("joobq:processing:#{name}").should eq(1)

        queue.stop!
        queue.start
        redis.llen(name).should eq(2) # after a stop, starting again reprocesses as the first start did
      ensure
        queue.try(&.stop!)
        [name, "joobq:processing:#{name}"].each { |key| redis.try(&.del(key)) } if name
      end

      it "processes enqueued jobs" do
        running_queue = Queue(ExampleJob).new("example", 2)
        store = JoobQ.store.as(RedisStore)
        10.times { |i| running_queue.add!(ExampleJob.new(i).to_json) }
        running_queue.size.should eq(10)
        running_queue.start
        eventually do
          store.redis.hget("joobq:stats:completed", "example") == "10" &&
            store.redis.llen("joobq:processing:example") == 0
        end.should be_true
        running_queue.size.should eq(0)
      ensure
        running_queue.try(&.stop!)
      end

      it "handles failing jobs with retries" do
        total_jobs = 5
        failed_queue = JoobQ["failed"]

        # Add failing jobs that will retry
        total_jobs.times do
          job = FailJob.new
          job.retries = 3
          failed_queue.add job.to_json
        end

        # Verify jobs were added
        failed_queue.size.should eq(total_jobs)
        failed_queue.running?.should be_false

        failed_queue.start

        # Give workers a moment to start
        sleep 0.1.seconds

        # Wait for workers to start running
        start_time = Time.instant
        while !failed_queue.running? && (Time.instant - start_time) < 5.seconds
          sleep 0.1.seconds
        end

        failed_queue.running?.should be_true

        # Wait for processing attempts (jobs will fail and retry)
        start_time = Time.instant
        while failed_queue.size > 0 && (Time.instant - start_time) < 20.seconds
          sleep 0.1.seconds
        end

        # Jobs should eventually be moved to dead letter queue after retries
        failed_queue.size.should eq(0)
        failed_queue.stop!
      end
    end

    # The future strict variant (Queue#add!) is meant to raise on unparseable input; these document today's swallow:
    # Queue#add(String) rescues the JSON error, logs it in handle_enqueue_error and returns nil.
    describe "#add(String) with invalid data" do
      # fetched here: the outer `queue` is reassigned by the #start example above (closure), so it is not reliably Queue(ExampleJob)
      it "current behaviour: swallows unparseable JSON, returns nil and enqueues nothing" do
        example = JoobQ["example"]
        example.clear
        result = example.add("not json")
        result.should be_nil
        example.size.should eq(0)
        JoobQ.store.as(RedisStore).redis.llen("example").should eq(0)
      end

      it "current behaviour: swallows valid JSON of the wrong shape, returns nil and enqueues nothing" do
        example = JoobQ["example"]
        example.clear
        result = example.add(%({"x": "not an int"}))
        result.should be_nil
        example.size.should eq(0)
        JoobQ.store.as(RedisStore).redis.llen("example").should eq(0)
      end
    end

    # describe "queue lifecycle" do
    #   # Ensure all queues and workers are stopped after these tests
    #   after_all do
    #     # Stop all queues to prevent interference with other specs
    #     JoobQ.queues.each do |name, queue|
    #       if queue.running?
    #         queue.stop!
    #       end
    #     end

    #     # Give workers time to fully terminate
    #     sleep 0.5.seconds

    #     # Verify all queues are stopped
    #     JoobQ.queues.each do |name, queue|
    #       unless queue.running? == false && queue.running_workers == 0
    #         puts "Warning: Queue '#{name}' still has #{queue.running_workers} running workers"
    #       end
    #     end
    #   end

    #   it "queues can be started and verify worker state" do
    #     # Pick a queue that hasn't been used yet
    #     queue = JoobQ["single"]

    #     # Ensure queue is not running initially
    #     queue.running?.should be_false
    #     queue.running_workers.should eq 0

    #     # Start the queue
    #     queue.start

    #     # Give workers time to start
    #     sleep 0.3.seconds

    #     # Verify queue is now running
    #     queue.running?.should be_true
    #     queue.running_workers.should be > 0
    #     queue.running_workers.should eq queue.total_workers

    #     # Stop the queue
    #     queue.stop!

    #     # Wait for workers to fully stop
    #     sleep 0.3.seconds

    #     # Verify queue has stopped
    #     queue.running?.should be_false
    #     queue.running_workers.should eq 0
    #   end

    #   it "has schedulers configured" do
    #     # Verify schedulers are available
    #     JoobQ.config.schedulers.should_not be_empty
    #     JoobQ.config.delayed_job_scheduler.should_not be_nil
    #   end
    # end

    # describe "processing_list" do
    #   it "returns jobs from processing queues" do
    #     store = JoobQ.store.as(JoobQ::RedisStore)

    #     # Clear any existing data
    #     store.reset

    #     # Create some test jobs and add them to processing queues
    #     job1 = ExampleJob.new(x: 1)
    #     job2 = ExampleJob.new(x: 2)
    #     job3 = Job1.new

    #     # Manually add jobs to processing queues to simulate jobs being processed
    #     processing_queue_1 = "joobq:processing:example"
    #     processing_queue_2 = "joobq:processing:single"

    #     store.redis.lpush(processing_queue_1, job1.to_json)
    #     store.redis.lpush(processing_queue_1, job2.to_json)
    #     store.redis.lpush(processing_queue_2, job3.to_json)

    #     # Test processing_list method
    #     processing_jobs = store.processing_list

    #     # Should return all jobs from processing queues
    #     processing_jobs.size.should eq 3
    #     processing_jobs.should contain(job1.to_json)
    #     processing_jobs.should contain(job2.to_json)
    #     processing_jobs.should contain(job3.to_json)

    #     # Test with limit
    #     limited_jobs = store.processing_list(limit: 2)
    #     limited_jobs.size.should eq 2

    #     # Test with custom pattern
    #     pattern_jobs = store.processing_list("joobq:processing:example", 10)
    #     pattern_jobs.size.should eq 2
    #     pattern_jobs.should contain(job1.to_json)
    #     pattern_jobs.should contain(job2.to_json)
    #     pattern_jobs.should_not contain(job3.to_json)

    #     # Clean up
    #     store.reset
    #   end
    # end
  end
end
