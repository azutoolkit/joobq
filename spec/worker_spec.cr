require "./spec_helper"

module JoobQ
  describe Worker do
    job = ExampleJob.new(1)
    queue = Queue(ExampleJob | FailJob).new("example", 1)
    done = Channel(Nil).new
    worker = Worker(ExampleJob | FailJob).new(1, done, queue)

    before_each do
      JoobQ.reset
    end

    describe "#active?" do
      it "stops worker gracefully" do
        worker.run
        worker.active?.should be_true
        worker.stop!
        worker.active?.should be_false
      end

      it "stops and syncs multiple workers" do
        w1 = Worker(ExampleJob | FailJob).new(1, done, queue)
        w2 = Worker(ExampleJob | FailJob).new(2, done, queue)

        w1.run
        w2.run

        w1.stop!
        w2.stop!

        w1.active?.should be_false
        w2.active?.should be_false
      end
    end

    it "runs the worker" do
      queue.store.queue_size(job.queue).should eq 0

      JoobQ.add job
      queue.store.queue_size(job.queue).should eq 1

      worker.run
      sleep 1.seconds

      worker.active?.should be_true
      queue.store.queue_size(job.queue).should eq 0
    end
  end
end
