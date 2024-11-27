module JoobQ
  # BaseQueue remains as the abstract base class
  abstract class BaseQueue
    abstract def add(job : String)
    abstract def start
    abstract def stop!
  end

  # The Queue class now focuses solely on queue operations
  class Queue(T) < BaseQueue
    getter store : Store = ::JoobQ.config.store
    getter name : String
    getter job_type : String = T.name
    getter total_workers : Int32
    getter worker_manager : WorkerManager(T) { WorkerManager(T).new(total_workers, self) }
    getter throttle_limit : NamedTuple(limit: Int32, period: Time::Span)?

    def initialize(@name : String, @total_workers : Int32,
                   @throttle_limit : NamedTuple(limit: Int32, period: Time::Span)? = nil)
    end

    def start
      reprocess_busy_jobs!
      worker_manager.start_workers
    end

    def parse_job(job : String) : T
      T.from_json(job)
    end

    def add(job : String)
      add T.from_json(job)
    rescue ex
      Log.error &.emit("Error Enqueuing", queue: name, error: ex.message, job: job)
    end

    def add(job : T)
      store.enqueue job
    rescue ex
      Log.error &.emit("Error Enqueuing", queue: name, error: ex.message, job: job.to_s)
    end

    def delete_job(job : String)
      store.delete_job job
    end

    def mark_as_dead(job : String)
      expires = JoobQ.config.dead_letter_ttl.total_seconds.to_i
      store.mark_as_dead job, expires
    end

    def retry(job : String)
      delay = (2 ** (job.retries)) * 1000 # Delay in ms
      store.schedule(job, delay)
    end

    def size : Int64
      store.queue_size name
    end

    def running? : Bool
      worker_manager.running?
    end

    def running_workers : Int32
      worker_manager.running_workers
    end

    def clear
      store.clear_queue name
    end

    def jobs(page_number : Int32 = 1, page_size : Int32 = 200)
      store.list_jobs(name)
    end

    def stop!
      worker_manager.stop_workers
    end

    def next_job
      store.dequeue(name, T)
    rescue ex
      Log.error &.emit("Error Dequeuing", queue: name, error: ex.message)
    end

    def status : String
      if size.zero? && running?
        return "Awaiting"
      end
      running? ? "Running" : "Done"
    end

    private def reprocess_busy_jobs!
      store.move_job_back_to_queue(name)
    end
  end
end
