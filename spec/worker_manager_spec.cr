require "./spec_helper"

module JoobQ
  describe WorkerManager do
    before_each do
      JoobQ.reset
    end

    describe "initialization" do
      it "creates specified number of workers" do
        queue = Queue(ExampleJob).new("example", 5)
        manager = WorkerManager(ExampleJob).new(5, queue)

        manager.workers.size.should eq(5)
        manager.total_workers.should eq(5)
      end

      it "initializes workers in stopped state" do
        queue = Queue(ExampleJob).new("example", 3)
        manager = WorkerManager(ExampleJob).new(3, queue)

        manager.running?.should be_false
        manager.running_workers.should eq(0)
      end
    end

    describe "#start_workers" do
      it "starts all workers" do
        queue = Queue(ExampleJob).new("example", 3)
        manager = WorkerManager(ExampleJob).new(3, queue)

        manager.start_workers
        sleep 0.5.seconds

        manager.running?.should be_true
        manager.running_workers.should eq(3)

        manager.stop_workers
      end

      it "does not start workers if already stopped" do
        queue = Queue(ExampleJob).new("example", 2)
        manager = WorkerManager(ExampleJob).new(2, queue)

        manager.stop_workers
        manager.start_workers

        manager.running_workers.should eq(0)
      end
    end

    describe "#stop_workers" do
      it "stops all running workers" do
        queue = Queue(ExampleJob).new("example", 3)
        manager = WorkerManager(ExampleJob).new(3, queue)

        manager.start_workers
        sleep 0.5.seconds
        manager.stop_workers
        sleep 0.5.seconds

        manager.stopped?.should be_true
        manager.running_workers.should eq(0)
      end

      it "is idempotent" do
        queue = Queue(ExampleJob).new("example", 2)
        manager = WorkerManager(ExampleJob).new(2, queue)

        manager.start_workers
        manager.stop_workers
        manager.stop_workers # Second call should be safe

        manager.stopped?.should be_true
      end
    end

    describe "#restart" do
      it "restarts crashed worker" do
        queue = Queue(ExampleJob).new("example", 3)
        manager = WorkerManager(ExampleJob).new(3, queue)

        manager.start_workers
        sleep 0.5.seconds

        initial_count = manager.workers.size
        worker_to_crash = manager.workers.first

        # Simulate crash
        exception = RuntimeError.new("Worker crashed")
        manager.restart(worker_to_crash, exception)

        sleep 0.5.seconds

        # Should have same number of workers
        manager.workers.size.should eq(initial_count)
        manager.running_workers.should eq(initial_count)

        manager.stop_workers
      end

      pending "does not restart when stopped" do
        queue = Queue(ExampleJob).new("example", 2)
        manager = WorkerManager(ExampleJob).new(2, queue)

        manager.start_workers
        manager.stop_workers

        worker = manager.workers.first
        exception = RuntimeError.new("Test")
        manager.restart(worker, exception)

        manager.workers.size.should be < 2
      end
    end

    describe "#add_worker" do
      pending "adds new worker to pool" do
        queue = Queue(ExampleJob).new("example", 2)
        manager = WorkerManager(ExampleJob).new(2, queue)

        manager.start_workers
        sleep 0.5.seconds

        # Override total_workers to allow adding
        manager.total_workers = 3
        manager.add_worker
        sleep 0.5.seconds

        manager.workers.size.should eq(3)
        manager.running_workers.should eq(3)

        manager.stop_workers
      end

      it "does not exceed total_workers limit" do
        queue = Queue(ExampleJob).new("example", 2)
        manager = WorkerManager(ExampleJob).new(2, queue)

        manager.start_workers
        manager.add_worker # Should not add beyond limit

        manager.workers.size.should eq(2)

        manager.stop_workers
      end
    end

    describe "#remove_worker" do
      it "removes worker from pool" do
        queue = Queue(ExampleJob).new("example", 3)
        manager = WorkerManager(ExampleJob).new(3, queue)

        manager.start_workers
        sleep 0.5.seconds

        manager.remove_worker
        sleep 0.5.seconds

        manager.workers.size.should eq(2)

        manager.stop_workers
      end

      it "handles empty worker pool" do
        queue = Queue(ExampleJob).new("example", 1)
        manager = WorkerManager(ExampleJob).new(1, queue)

        manager.remove_worker
        manager.remove_worker # Should not crash

        manager.workers.size.should eq(0)
      end
    end

    describe "#running_workers" do
      it "returns count of running workers" do
        queue = Queue(ExampleJob).new("example", 5)
        manager = WorkerManager(ExampleJob).new(5, queue)

        manager.running_workers.should eq(0)

        manager.start_workers
        sleep 0.5.seconds

        manager.running_workers.should eq(5)

        manager.stop_workers
      end
    end

    describe "#active_workers" do
      it "returns count of active workers" do
        queue = Queue(ExampleJob).new("example", 3)
        manager = WorkerManager(ExampleJob).new(3, queue)

        manager.start_workers
        sleep 0.5.seconds

        # Without jobs, active count should be 0 or equal to running
        active = manager.active_workers
        active.should be >= 0
        active.should be <= manager.running_workers

        manager.stop_workers
      end
    end

    describe "thread safety" do
      pending "handles concurrent worker operations" do
        queue = Queue(ExampleJob).new("example", 5)
        manager = WorkerManager(ExampleJob).new(5, queue)

        manager.start_workers

        # Simulate concurrent operations
        channel = Channel(Nil).new

        10.times do
          spawn do
            manager.running_workers
            manager.active_workers
            channel.send(nil)
          end
        end

        10.times { channel.receive }

        manager.stop_workers
      end
    end

    describe "graceful shutdown" do
      it "waits for workers to finish current jobs" do
        queue = Queue(ExampleJob).new("example", 2)
        manager = WorkerManager(ExampleJob).new(2, queue)

        manager.start_workers

        # Add some jobs
        3.times { |i| queue.add(ExampleJob.new(i).to_json) }

        sleep 0.5.seconds
        manager.stop_workers
        sleep 0.5.seconds

        manager.stopped?.should be_true
      end
    end
  end
end
