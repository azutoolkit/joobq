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
      pending "processes enqueued jobs" do
        total_jobs = 10

        total_jobs.times do |i|
          queue.add ExampleJob.new(i).to_json
        end

        total_jobs.times do
          job = FailJob.new
          job.queue = "example"
          job.retries = 3
          queue.add job.to_json
        end

        queue.size.should eq(total_jobs * 2)
        queue.running?.should be_false

        queue.start
        sleep 10

        queue.running?.should be_true
        queue.size.should be < total_jobs
        queue.stop!
      end
    end
  end
end
