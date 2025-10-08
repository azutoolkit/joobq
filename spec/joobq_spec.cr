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

  describe ".forge" do
    it "starts all registered queues" do
      # Ensure queues are not running initially
      JoobQ.queues.each do |name, queue|
        queue.running?.should be_false
      end

      # Spawn forge in a separate fiber since it blocks with sleep
      forge_fiber = spawn do
        JoobQ.forge
      end

      # Give queues time to start
      sleep 0.5.seconds

      # Verify all queues are now running
      JoobQ.queues.each do |name, queue|
        queue.running?.should be_true
        queue.running_workers.should be > 0
      end

      # Clean up - stop all queues
      JoobQ.queues.each do |name, queue|
        queue.stop!
      end

      # Wait for workers to stop
      sleep 0.2.seconds

      # Verify queues have stopped
      JoobQ.queues.each do |name, queue|
        queue.running?.should be_false
      end
    end

    it "starts schedulers when forge is called" do
      # Spawn forge in a separate fiber
      forge_fiber = spawn do
        JoobQ.forge
      end

      # Give schedulers time to start
      sleep 0.5.seconds

      # Verify schedulers are initialized
      JoobQ.config.schedulers.should_not be_empty
      JoobQ.config.delayed_job_scheduler.should_not be_nil

      # Clean up
      JoobQ.queues.each do |name, queue|
        queue.stop!
      end
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
