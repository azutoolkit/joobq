module JoobQ
  # BaseQueue remains as the abstract base class
  module BaseQueue
    abstract def add(job : String)
    abstract def start
    abstract def stop!
    abstract def name : String
    abstract def size : Int64
    abstract def job_type : String
    abstract def total_workers : Int32
    abstract def running_workers : Int32
    abstract def status : String
    abstract def throttle_limit : NamedTuple(limit: Int32, period: Time::Span)?
  end

  # The Queue class now focuses solely on queue operations
  class Queue(T)
    include BaseQueue
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
      handle_enqueue_error(ex, job, "string_job")
    end

    def add(job : T)
      store.enqueue job
    rescue ex
      handle_enqueue_error(ex, job.to_json, "typed_job")
    end

    private def handle_enqueue_error(ex : Exception, job_data : String, job_type : String)
      error_context = {
        queue: name,
        job_type: job_type,
        error_class: ex.class.name,
        error_message: ex.message || "Unknown error",
        job_data_length: job_data.size.to_s,
        queue_size: size.to_s,
        queue_workers: total_workers.to_s,
        occurred_at: Time.local.to_rfc3339
      }

      Log.error &.emit("Failed to enqueue job", error_context)

      # For critical enqueue failures, we might want to raise or handle differently
      case ex
      when Redis::CannotConnectError
        Log.error &.emit("Redis connection failed during enqueue", error_context)
        raise ex # Re-raise connection errors as they're critical
      when JSON::Error
        Log.error &.emit("Invalid job data format", error_context)
        # Don't re-raise JSON errors, just log them
      else
        Log.error &.emit("Unexpected error during enqueue", error_context)
      end
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

    def next_job : String?
      store.dequeue(name, T)
    rescue ex
      Log.error &.emit("Error Dequeuing", queue: name, error: ex.message)
      nil
    end

    def claim_job(worker_id : String) : String?
      store.claim_job(name, worker_id, T)
    rescue ex
      Log.error &.emit("Error Claiming Job", queue: name, worker: worker_id, error: ex.message)
      nil
    end

    def claim_jobs_batch(worker_id : String, batch_size : Int32 = 5) : Array(String)
      store.claim_jobs_batch(name, worker_id, T, batch_size)
    rescue ex
      Log.error &.emit("Error Claiming Jobs Batch", queue: name, worker: worker_id,
                      batch_size: batch_size, error: ex.message)
      [] of String
    end

    def release_job_claim(worker_id : String) : Nil
      store.release_job_claim(name, worker_id)
    rescue ex
      Log.error &.emit("Error Releasing Job Claim", queue: name, worker: worker_id, error: ex.message)
    end

    def release_job_claims_batch(worker_id : String, job_count : Int32) : Nil
      store.release_job_claims_batch(name, worker_id, job_count)
    rescue ex
      Log.error &.emit("Error Releasing Job Claims Batch", queue: name, worker: worker_id,
                      job_count: job_count, error: ex.message)
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
