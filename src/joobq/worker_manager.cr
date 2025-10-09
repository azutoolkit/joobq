module JoobQ
  # WorkerManager handles all worker-related operations
  class WorkerManager(T)
    getter workers : Array(Worker(T)) = [] of Worker(T)
    getter workers_mutex = Mutex.new
    getter terminate_channel : Channel(Nil) = Channel(Nil).new
    property total_workers : Int32
    getter stopped : Atomic(Bool) = Atomic(Bool).new(false)

    def initialize(@total_workers : Int32, @queue : Queue(T))
      create_workers
    end

    def start_workers
      @workers_mutex.synchronize do
        return if stopped.get
        @workers.each &.run
      end
    end

    def stop_workers
      had_running_workers = false

      @workers_mutex.synchronize do
        return if stopped.get
        stopped.set(true)

        # Check if any workers are running before sending termination signals
        had_running_workers = @workers.any?(&.running?)
        if had_running_workers
          @workers.size.times { terminate_channel.send(nil) }
        end
      end

      # Only wait for termination if there were workers that were running
      if had_running_workers
        wait_for_workers_to_stop
      end
    end

    def running_workers : Int32
      @workers_mutex.synchronize do
        return 0 if stopped.get
        @workers.count &.running?
      end
    end

    def active_workers : Int32
      @workers_mutex.synchronize do
        return 0 if stopped.get
        @workers.count &.active?
      end
    end

    def running? : Bool
      @workers_mutex.synchronize do
        return false if stopped.get
        @workers.any? &.running?
      end
    end

    def stopped? : Bool
      stopped.get
    end

    def terminate(worker)
      @workers_mutex.synchronize do
        @workers.delete(worker)
      end
    end

    def restart(worker, ex : Exception)
      @workers_mutex.synchronize do
        # Remove the failed worker
        @workers.delete(worker)

        # Only restart if we still need workers and haven't been stopped
        return if stopped.get || @workers.size >= total_workers

        # Create and start a new worker
        new_worker = create_worker
        @workers << new_worker
        new_worker.run
      end
    end

    def add_worker
      @workers_mutex.synchronize do
        return if stopped.get || @workers.size >= total_workers
        worker = create_worker
        @workers << worker
        worker.run
      end
    end

    def remove_worker
      @workers_mutex.synchronize do
        return if @workers.empty?
        worker = @workers.pop
        worker.terminate
      end
    end

    private def create_workers
      @workers_mutex.synchronize do
        @total_workers.times { @workers << create_worker }
      end
    end

    private def create_worker
      Worker(T).new(@workers.size, terminate_channel, @queue)
    end

    private def wait_for_workers_to_stop
      # Wait up to 5 seconds for all workers to stop
      timeout = 5.seconds
      start_time = Time.monotonic

      while Time.monotonic - start_time < timeout
        @workers_mutex.synchronize do
          all_stopped = @workers.all? { |worker| !worker.running? }
          if all_stopped
            return
          end
        end
        sleep 10.milliseconds
      end

      # If we reach here, some workers didn't stop in time
      # Log a warning but don't block indefinitely
      @workers_mutex.synchronize do
        still_running = @workers.select(&.running?)
        if !still_running.empty?
          Log.warn &.emit("Some workers did not stop within timeout",
            still_running_count: still_running.size,
            total_workers: @workers.size)
        end
      end
    end
  end
end
