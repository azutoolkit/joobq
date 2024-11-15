module JoobQ
  abstract class BaseQueue
    abstract def add(job : String)
  end

  class Queue(T) < BaseQueue
    getter store : Store = JoobQ.config.store
    getter name : String
    getter total_workers : Int32
    getter jobs : String = T.to_s

    property completed : Atomic(Int64) = Atomic(Int64).new(0)
    property retried : Atomic(Int64) = Atomic(Int64).new(0)
    property dead : Atomic(Int64) = Atomic(Int64).new(0)
    property busy : Atomic(Int64) = Atomic(Int64).new(0)
    property start_time : Time::Span = Time.monotonic
    property throttle_limit : Int32? = nil

    # Use a Channel for job distribution
    private getter terminate_channel : Channel(Nil) = Channel(Nil).new
    private getter workers : Array(Worker(T)) = Array(Worker(T)).new
    private getter workers_mutex = Mutex.new

    def initialize(@name : String, @total_workers : Int32, @throttle_limit : Int32? = nil)
      create_workers
    end

    def parse_job(job_data : JSON::Any)
      T.from_json job_data.as(String)
    end

    def start
      reprocess_busy_jobs!
      workers.each &.run
    end

    def add(job : String)
      add T.from_json(job)
    end

    def add(job : T)
      store.enqueue job
    rescue ex
      Log.error &.emit("Error Enqueuing", queue: name, error: ex.message)
    end

    def size
      store.queue_size name
    end

    def running?
      workers.all? &.active?
    end

    def running_workers
      workers.count &.active?
    end

    def clear
      store.clear_queue name
    end

    def stop!
      total_workers.times do
        terminate_channel.send(nil)
      end
    end

    def next_job
      # Try to get a job from the store
      store.dequeue(name, T)
    rescue ex
      Log.error &.emit("Error Dequeuing", queue: name, error: ex.message)
    end

    def status
      case {size.zero?, running?}
      when {true, true}  then "Awaiting"
      when {false, true} then "Running"
      else                    "Done"
      end
    end

    def terminate(worker : Worker(T))
      Log.warn &.emit("Terminating Worker", queue: name, worker_id: worker.wid)
      @workers_mutex.synchronize do
        workers.delete worker
      end
    end

    def restart(worker : Worker(T), ex : Exception)
      terminate worker
      return unless running?

      Log.warn &.emit("Restarting Worker!", queue: name, worker_id: worker.wid)
      worker = create_worker
      @workers_mutex.synchronize do
        workers << worker
      end
      worker.run
      worker
    end

    def info
      {
        name:                name,
        total_workers:       total_workers,
        status:              status,
        enqueued:            size,
        completed:           completed.get,
        retried:             retried.get,
        dead:                dead.get,
        processing:          busy.get,
        running_workers:     running_workers,
        jobs_per_second:     jobs_per_second,
        errors_per_second:   errors_per_second,
        enqueued_per_second: enqueued_per_second,
        jobs_latency:        jobs_latency,
        elapsed_time:        Time.monotonic - start_time,
      }
    end

    def jobs_per_second
      elapsed_time = Time.monotonic - @start_time
      return 0.0 if status == "Awaiting" || elapsed_time == 0
      (completed.get.to_f / elapsed_time.to_f)
    end

    def errors_per_second
      elapsed_time = Time.monotonic - @start_time
      return 0.0 if status == "Awaiting" || elapsed_time == 0
      (retried.get.to_f / elapsed_time.to_f)
    end

    def enqueued_per_second
      elapsed_time = Time.monotonic - @start_time
      return 0.0 if status == "Awaiting" || elapsed_time == 0
      (size.to_f / elapsed_time.to_f)
    end

    def jobs_latency
      elapsed_time = Time.monotonic - @start_time
      return 0 if status == "Awaiting" || completed.get == 0
      elapsed_time / completed.get
    end

    private def reprocess_busy_jobs!
      @store.move_job_back_to_queue(name)
    end

    private def create_workers
      total_workers.times do
        workers << create_worker
      end
    end

    private def create_worker
      Worker(T).new workers.size, terminate_channel, self
    end
  end
end
