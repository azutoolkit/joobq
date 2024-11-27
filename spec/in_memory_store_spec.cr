require "./spec_helper"

# Tests for InMemoryStore
describe JoobQ::InMemoryStore do
  store = JoobQ::InMemoryStore.new
  job1 = ExampleJob.new(x: 1)
  job2 = ExampleJob.new(x: 2)

  before_each do
    store.queues[job1.queue] = [] of JoobQ::Job
  end

  describe "#initialize" do
    it "starts with empty queues and no scheduled jobs" do
      store.queue_size(queue_name: "default").should eq(0)
      store.fetch_due_jobs(current_time: Time.local).should be_empty
    end
  end

  describe "#enqueue" do
    it "adds a job to the specified queue" do
      store.enqueue(job: job1)
      store.queue_size(queue_name: job1.queue).should eq(1)
    end
  end

  describe "#dequeue" do
    context "when the queue has jobs" do
      it "removes and returns the first job" do
        store.queues[job1.queue] = [] of JoobQ::Job
        store.enqueue(job: job1)
        store.enqueue(job: job2)

        if dequeued_job = store.dequeue(queue_name: job1.queue, klass: ExampleJob)
          job = ExampleJob.from_json(dequeued_job)
          job.should eq(job1)

          store.queue_size(queue_name: job1.queue).should eq(1)
        end
      end
    end

    context "when the queue is empty" do
      it "returns nil" do
        store.dequeue(queue_name: "empty_queue", klass: ExampleJob).should be_nil
      end
    end
  end

  describe "#clear_queue" do
    it "removes all jobs from the queue" do
      store.enqueue(job: job1)
      store.enqueue(job: job2)

      store.clear_queue(queue_name: job1.queue)
      store.queue_size(queue_name: job1.queue).should eq(0)
    end
  end

  describe "#delete_job" do
    it "removes a specific job from the queue" do
      store.queues[job1.queue] = [] of JoobQ::Job

      store.enqueue(job: job1)
      store.enqueue(job: job2)

      store.delete_job(job: job1.to_json)

      store.queue_size(queue_name: job1.queue).should eq(1)
      if job_json = store.dequeue(queue_name: job1.queue, klass: ExampleJob)
        job = ExampleJob.from_json(job_json)
        job.should eq(job2)
      end
    end
  end

  describe "#move_job_back_to_queue" do
    it "requeues a job that was being processed" do
      store.enqueue(job: job1)
      store.move_job_back_to_queue(queue_name: job1.queue)
      store.queue_size(queue_name: job1.queue).should eq(1)
    end
  end

  describe "#mark_as_dead" do
    it "stores a dead job with an expiration time" do
      expiration_time = (Time.local.to_unix_ms + 3600).to_i64
      store.mark_as_dead(job: job1, expiration_time: expiration_time)

      dead_jobs = store.dead_jobs
      dead_jobs.size.should eq(1)
      dead_jobs.first.job.should eq(job1)
      dead_jobs.first.expiration_time.should eq(expiration_time)
    end
  end

  describe "#schedule" do
    it "stores a job with a future execution time" do
      store.schedule(job: job1, delay_in_ms: 5000) # 5 seconds delay
      scheduled_jobs = store.scheduled_jobs
      scheduled_jobs.size.should eq(1)
      scheduled_jobs.first.job.should eq(job1)
    end
  end

  describe "#fetch_due_jobs" do
    context "when jobs are due" do
      it "returns jobs ready for execution" do
        store.schedule(job: job1, delay_in_ms: 0)      # Immediate execution
        store.schedule(job: job2, delay_in_ms: 10_000) # 10 seconds delay

        due_jobs = store.fetch_due_jobs(current_time: Time.local)
        due_jobs.size.should eq(1)
        due_jobs.first.should contain(%("x":1))
      end
    end

    context "when jobs are not yet due" do
      it "returns an empty array" do
        store.schedule(job: job1, delay_in_ms: 10_000) # 10 seconds delay

        due_jobs = store.fetch_due_jobs(current_time: Time.local)
        due_jobs.should be_empty
      end
    end
  end

  describe "#queue_size" do
    it "returns the correct number of jobs in a queue" do
      store.queues[job1.queue] = [] of JoobQ::Job

      store.enqueue(job: job1)
      store.enqueue(job: job2)
      store.queue_size(queue_name: job1.queue).should eq(2)
    end
  end

  describe "#list_jobs" do
    it "lists jobs in a queue with pagination" do
      5.times do |i|
        job = ExampleJob.new(x: i)
        store.enqueue(job: job)
      end

      jobs_page1 = store.list_jobs(queue_name: "example", page_number: 1, page_size: 2)
      jobs_page2 = store.list_jobs(queue_name: "example", page_number: 2, page_size: 2)

      jobs_page1.size.should eq(2)
      jobs_page2.size.should eq(2)
    end
  end
end
