require "./spec_helper"

module JoobQ
  describe Worker do

    queue = Queue(Example).new("example", 1)
    done = Channel(Nil).new
    control = Channel(Nil).new
    worker = queue.workers.first
    job = ExampleJob.new(1)

    before_each { JoobQ.reset }

    describe "#running?" do
      it "stops worker gracefully" do
        worker.run
        worker.running?.should be_true

        worker.stop!

        worker.running?.should be_false
      end

      it "stops and syncs multiple workers" do
        d1 = Channel(Nil).new
        c1 = Channel(Nil).new
        w1 = Worker(ExampleJob | FailJob).new(queue, 1, c1, d1)
        w2 = Worker(ExampleJob | FailJob).new(queue, 2, c1, d1)

        w1.run
        w2.run

        w1.stop!
        w2.stop!

        w1.running?.should be_false
        w2.running?.should be_false
      end
    end

    it "process job" do
      worker.process job, job.to_json

      redis.llen(job.queue).should eq 0
      redis.zcard(Sets::Dead.to_s).should eq 0
      redis.zcard(Sets::Retry.to_s).should eq 0
      redis.llen(Queues::Busy.to_s).should eq 0
    end

    it "retries job" do
      job = FailJob.new
      job.retries = 2

      worker.process job, job.to_json

      redis.llen(job.queue).should eq 0
      redis.zcard(Sets::Dead.to_s).should eq 0
      redis.zcard(Sets::Retry.to_s).should eq 1
      redis.llen(Queues::Busy.to_s).should eq 0
    end

    it "dead job" do
      job = FailJob.new

      worker.process job, job.to_json

      redis.llen(job.queue).should eq 0
      redis.zcard(Sets::Dead.to_s).should eq 1
      redis.zcard(Sets::Retry.to_s).should eq 0
      redis.llen(Queues::Busy.to_s).should eq 0
    end
  end
end
