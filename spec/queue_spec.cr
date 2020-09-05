require "./spec_helper"

module JoobQ
  describe Queue do
    job = ExampleJob.new 1
    total_jobs = 100
    queue = JoobQ["example"]

    before_each do
      JoobQ.reset
      queue.clear
    end

    describe "#stop!" do
      it "stops all workers" do
        single_queue = JoobQ["single"]
        single_queue.process
        single_queue.running?.should be_true

        single_queue.stop!

        single_queue.running?.should be_false
        single_queue.clear
      end
    end

    describe "#process" do
      it "runs a job" do
        total_jobs.times do |i|
          queue.push ExampleJob.new(i).to_json
        end

        total_jobs.times do
          job = FailJob.new
          job.queue = "example"
          job.retries = 3
          queue.push job.to_json
        end

        queue.size.should eq (total_jobs * 2)
        queue.running?.should be_false

        queue.process
        sleep 1

        queue.running?.should be_true
        queue.size.should eq 0
        redis.llen(Queues::Busy.to_s).should eq 0
        redis.zcard(Sets::Retry.to_s).should eq 100
        queue.stop!
      end
    end
  end
end
