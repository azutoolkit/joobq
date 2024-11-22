module JoobQ
  # BaseQueue remains as the abstract base class
  abstract class BaseQueue
    abstract def add(job : String)
    abstract def start
    abstract def stop!
  end

  # The Queue class now focuses on queue operations
  class Queue(T) < BaseQueue
    getter store : Store = ::JoobQ.config.store
    getter name : String
    getter job_type : String = T.name
    getter total_workers : Int32
    getter metrics : Metrics
    getter worker_manager : WorkerManager(T) { WorkerManager(T).new(total_workers, self, metrics) }
    getter throttle_limit : ThrottlerConfig?

    def initialize(@name : String, @total_workers : Int32, @throttle_limit : ThrottlerConfig? = nil)
      @metrics = Metrics.new
    end

    def start
      metrics.start_time = Time.monotonic
      reprocess_busy_jobs!
      worker_manager.start_workers
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

    def info
      current_queue_size = size
      result = {
        name:                      name,
        job_type:                  job_type,
        total_workers:             total_workers,
        status:                    status,
        current_size:              current_queue_size,
        completed:                 metrics.completed.get,
        retried:                   metrics.retried.get,
        dead:                      metrics.dead.get,
        running_workers:           running_workers,
        jobs_completed_per_second: metrics.jobs_completed_per_second,
        queue_reduction_rate:      metrics.queue_reduction_rate(current_queue_size),
        errors_per_second:         metrics.errors_per_second,
        job_wait_time:             metrics.job_wait_time,
        job_execution_time:        metrics.job_execution_time,
        worker_utilization:        metrics.worker_utilization(total_workers),
        error_rate_trend:          metrics.error_rate_trend,
        failed_job_rate:           metrics.failed_job_rate,
        average_jobs_in_flight:    metrics.average_jobs_in_flight,
        percent_completed:         metrics.percent_completed,
        percent_retried:           metrics.percent_retried,
        percent_dead:              metrics.percent_dead,
        percent_busy:              metrics.percent_busy,
      }
      result
    end

    private def reprocess_busy_jobs!
      store.move_job_back_to_queue(name)
    end
  end
end
