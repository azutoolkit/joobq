require "./spec_helper"

module JoobQ
  describe Queue do
    job = ExampleJob.new 1
    total_jobs = 100
    queue = JoobQ["example"]

    before_each do
      redis.del "example"
      JoobQ.reset
      queue.stop!
    end

    describe "#size" do
      it "returns zero for empty queue" do
        queue.size.should eq 0
      end

      it "returns 1 when queue has a job" do
        queue.push job.to_json
        queue.size.should eq 1
      end
    end

    describe "#running? and #status?" do
      it "is not running when instantiated" do
        queue.running?.should be_false
        queue.status.should eq "Done"
        queue.running_workers.should eq 0
      end

      it "is pending when stoppend and has enqueued jobs" do
        queue.push job.to_json
        queue.running?.should be_false
        queue.status.should eq "Running"
        queue.running_workers.should eq 0
      end

      it "is Running when processing" do
        queue.push job.to_json
        queue.process
        queue.running?.should be_true
        queue.status.should eq "Running"
        queue.running_workers.should eq 1
      end

      it "is still running when there is no job in the queue" do
        queue.push job.to_json
        queue.process
        sleep 1
        queue.running?.should be_true
        queue.status.should eq "Done"
        queue.running_workers.should eq 1
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

        start = Time.local
        queue.process
        sleep 3

        queue.size.should eq 0
        redis.llen(Queues::Busy.to_s).should eq 0
        redis.zcard(Sets::Retry.to_s).should eq 100
      end
    end

    describe "queueing" do
      it "adds item to queue" do
        queue.clear
        queue.push job.to_json
        queue.size.should eq 1
      end
    end
  end
end
