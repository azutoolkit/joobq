module JoobQ
  # WorkerManager handles all worker-related operations
  class WorkerManager(T)
    getter workers : Array(Worker(T)) = [] of Worker(T)
    getter workers_mutex = Mutex.new
    getter terminate_channel : Channel(Nil) = Channel(Nil).new
    getter total_workers : Int32

    def initialize(@total_workers : Int32, @queue : Queue(T), @metrics : Metrics)
      create_workers
    end

    def start_workers
      workers.each &.run
    end

    def stop_workers
      workers.size.times { terminate_channel.send(nil) }
    end

    def running_workers : Int32
      workers.count &.active?
    end

    def running? : Bool
      workers.all? &.active?
    end

    def terminate(worker)
      workers_mutex.synchronize { workers.delete(worker) }
    end

    def restart(worker, ex : Exception)
      terminate worker
      return unless running?
      worker = create_worker
      workers_mutex.synchronize { workers << worker }
      worker.run
    end

    private def create_workers
      total_workers.times { workers << create_worker }
    end

    private def create_worker
      Worker(T).new(workers.size, terminate_channel, @queue, @metrics)
    end
  end
end
