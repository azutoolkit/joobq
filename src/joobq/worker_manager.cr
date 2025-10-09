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
      @workers_mutex.synchronize do
        return if stopped.get
        stopped.set(true)
        @workers.size.times { terminate_channel.send(nil) }
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
        return if stopped.get

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
  end
end
