require "./spec_helper"

describe JoobQ do
  it "registers a queue" do
    JoobQ.queues.size.should eq 3
  end

  it "gets queue by name" do
    JoobQ["example"].should be_a JoobQ::Queue(ExampleJob)
    JoobQ["single"].should be_a JoobQ::Queue(Job1)
  end

  it "registers recurring jobs at specific time" do
    jobs = JoobQ.config.schedulers.first.cron_scheduler.jobs

    jobs["*/30 * * * *:America/New_York"].should_not be_nil
    jobs["*/5 20-23 * * *:America/New_York"].should_not be_nil
    # jobs[ExampleJob.name].should_not be_nil
  end

  describe "queue lifecycle" do
    # Ensure all queues and workers are stopped after these tests
    after_all do
      # Stop all queues to prevent interference with other specs
      JoobQ.queues.each do |name, queue|
        if queue.running?
          queue.stop!
        end
      end

      # Give workers time to fully terminate
      sleep 0.5.seconds

      # Verify all queues are stopped
      JoobQ.queues.each do |name, queue|
        unless queue.running? == false && queue.running_workers == 0
          puts "Warning: Queue '#{name}' still has #{queue.running_workers} running workers"
        end
      end
    end

    it "queues can be started and verify worker state" do
      # Pick a queue that hasn't been used yet
      queue = JoobQ["single"]

      # Ensure queue is not running initially
      queue.running?.should be_false
      queue.running_workers.should eq 0

      # Start the queue
      queue.start

      # Give workers time to start
      sleep 0.3.seconds

      # Verify queue is now running
      queue.running?.should be_true
      queue.running_workers.should be > 0
      queue.running_workers.should eq queue.total_workers

      # Stop the queue
      queue.stop!

      # Wait for workers to fully stop
      sleep 0.3.seconds

      # Verify queue has stopped
      queue.running?.should be_false
      queue.running_workers.should eq 0
    end

    it "has schedulers configured" do
      # Verify schedulers are available
      JoobQ.config.schedulers.should_not be_empty
      JoobQ.config.delayed_job_scheduler.should_not be_nil
    end
  end

  describe "processing_list" do
    it "returns jobs from processing queues" do
      store = JoobQ.store.as(JoobQ::RedisStore)

      # Clear any existing data
      store.reset

      # Create some test jobs and add them to processing queues
      job1 = ExampleJob.new(x: 1)
      job2 = ExampleJob.new(x: 2)
      job3 = Job1.new

      # Manually add jobs to processing queues to simulate jobs being processed
      processing_queue_1 = "joobq:processing:example"
      processing_queue_2 = "joobq:processing:single"

      store.redis.lpush(processing_queue_1, job1.to_json)
      store.redis.lpush(processing_queue_1, job2.to_json)
      store.redis.lpush(processing_queue_2, job3.to_json)

      # Test processing_list method
      processing_jobs = store.processing_list

      # Should return all jobs from processing queues
      processing_jobs.size.should eq 3
      processing_jobs.should contain(job1.to_json)
      processing_jobs.should contain(job2.to_json)
      processing_jobs.should contain(job3.to_json)

      # Test with limit
      limited_jobs = store.processing_list(limit: 2)
      limited_jobs.size.should eq 2

      # Test with custom pattern
      pattern_jobs = store.processing_list("joobq:processing:example", 10)
      pattern_jobs.size.should eq 2
      pattern_jobs.should contain(job1.to_json)
      pattern_jobs.should contain(job2.to_json)
      pattern_jobs.should_not contain(job3.to_json)

      # Clean up
      store.reset
    end
  end
end
