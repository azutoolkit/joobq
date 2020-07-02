require "./spec_helper"

module JoobQ
  describe Worker do
    queue = "example"
    worker = Worker(ExampleJob | FailJob).new(queue, 1)
    job = ExampleJob.new(1)

    describe "#running?" do
      it "returns false when is done" do
        worker = Worker(ExampleJob | FailJob).new(queue, 1)

        worker.running?.should be_false
        worker.run
        worker.running?.should be_true
        worker.add job
        sleep 1
        worker.running?.should be_false
      end
    end

    context "worker states COMPLETE, RETRY and DEAD" do
      before_each do
        JoobQ.reset
        REDIS.del job.queue
        worker.run
      end

      context "processing" do
        it "process job" do
          worker.add job
          sleep 1.microsecond

          redis.llen(job.queue).should eq 0
          redis.zcard(Sets::Dead.to_s).should eq 0
          redis.zcard(Sets::Retry.to_s).should eq 0
          redis.llen(Queues::Busy.to_s).should eq 0
        end

        it "retries job" do
          job = FailJob.new
          job.retries = 2

          worker.add job
          sleep 1.microsecond

          redis.llen(job.queue).should eq 0
          redis.zcard(Sets::Dead.to_s).should eq 0
          redis.zcard(Sets::Retry.to_s).should eq 1
          redis.llen(Queues::Busy.to_s).should eq 0
        end

        it "dead job" do
          job = FailJob.new

          worker.add job
          sleep 1.microsecond

          redis.llen(job.queue).should eq 0
          redis.zcard(Sets::Dead.to_s).should eq 1
          redis.zcard(Sets::Retry.to_s).should eq 0
          redis.llen(Queues::Busy.to_s).should eq 0
        end
      end
    end
  end
end
