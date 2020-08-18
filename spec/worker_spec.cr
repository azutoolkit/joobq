require "./spec_helper"

module JoobQ
  describe Worker do
    queue = "example"
    channel = Channel(ExampleJob | FailJob).new(1)
    worker = Worker(ExampleJob | FailJob).new(queue, 1, channel)
    job = ExampleJob.new(1)

    before_each do
      redis.del "example"
      JoobQ.reset
    end

    describe "#running?" do
      it "returns false when is done" do
        worker = Worker(ExampleJob | FailJob).new(queue, 1, channel)

        worker.running?.should be_false
        worker.run
        worker.running?.should be_true
        channel.send job
        sleep 1
        worker.running?.should be_true
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
          channel.send job
          sleep 1.microsecond

          redis.llen(job.queue).should eq 0
          redis.zcard(Sets::Dead.to_s).should eq 0
          redis.zcard(Sets::Retry.to_s).should eq 0
          redis.llen(Queues::Busy.to_s).should eq 0
        end

        it "retries job" do
          job = FailJob.new
          job.retries = 2

          channel.send job
          sleep 1.microsecond

          redis.llen(job.queue).should eq 0
          redis.zcard(Sets::Dead.to_s).should eq 0
          redis.zcard(Sets::Retry.to_s).should eq 1
          redis.llen(Queues::Busy.to_s).should eq 0
        end

        it "dead job" do
          job = FailJob.new

          channel.send job
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
