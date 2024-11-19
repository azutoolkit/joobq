module JoobQ
  abstract class BaseQueue
    abstract def add(job : String)
  end

  class Queue(T) < BaseQueue
    getter store : Store = ::JoobQ.config.store
    getter name : String
    getter total_workers : Int32
    getter jobs : String = T.to_s
    getter throttle_limit : NamedTuple(limit: Int32, period: Time::Span)? = nil


    property completed : Atomic(Int64) = Atomic(Int64).new(0)
    property retried : Atomic(Int64) = Atomic(Int64).new(0)
    property busy : Atomic(Int64) = Atomic(Int64).new(0)
    property dead : Atomic(Int64) = Atomic(Int64).new(0)
    property total_jobs_enqueued : Int64 { size }
    property total_job_wait_time : Time::Span = Time::Span.zero
    property total_job_execution_time : Time::Span = Time::Span.zero
    property last_queue_size : Int64 = 0_i64
    property last_queue_time : Time::Span = Time.monotonic
    property start_time : Time::Span = Time.monotonic

    private getter terminate_channel : Channel(Nil) = Channel(Nil).new
    private getter workers : Array(Worker(T)) = Array(Worker(T)).new
    private getter workers_mutex = Mutex.new

    getter jobs_completed_per_second : Float64 { per_second_rate(completed.get) }
    getter errors_per_second : Float64 { per_second_rate(retried.get) }
    getter enqueued_per_second : Float64 { per_second_rate(total_jobs_enqueued) }
    getter percent_completed : Float64 { percentage_rate(completed.get, total_jobs_enqueued) }


    getter queue_reduction_rate : Float64 do
      current_time = Time.monotonic
      time_delta = current_time - last_queue_time
      return 0.0 if time_delta.total_seconds == 0.0

      current_queue_size = size
      size_delta = last_queue_size - current_queue_size

      reduction_rate = size_delta.to_f / time_delta.total_seconds

      @last_queue_size = current_queue_size
      @last_queue_time = current_time

      reduction_rate.round(2)
    end

    getter job_wait_time : Float64 { average_time(total_job_wait_time, completed.get) }
    getter job_execution_time : Float64 { average_time(total_job_execution_time, completed.get) }

    getter worker_utilization : Float64 do
      total_worker_time = total_workers.to_f * elapsed_time.total_seconds
      return 0.0 if total_worker_time == 0.0
      utilization = (total_job_execution_time.total_seconds / total_worker_time) * 100.0
      utilization.clamp(0.0, 100.0).round(2)
    end

    getter error_rate_trend : Float64 do
      total_attempted_jobs = completed.get + retried.get + dead.get
      percentage_rate(retried.get, total_attempted_jobs)
    end

    getter failed_job_rate : Float64 do
      total_processed_jobs = completed.get + dead.get
      percentage_rate(dead.get, total_processed_jobs)
    end

    def initialize(@name : String, @total_workers : Int32, @throttle_limit : NamedTuple(limit: Int32, period: Time::Span)? = nil)
      @last_queue_size = size
      @last_queue_time = Time.monotonic
      create_workers
    end

    def start
      @start_time = Time.monotonic
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

    def size : Int64
      store.queue_size name
    end

    def running? : Bool
      workers.all? &.active?
    end

    def running_workers : Int32
      workers.count &.active?
    end

    def clear
      store.clear_queue name
    end

    def stop!
      total_workers.times { terminate_channel.send(nil) }
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

    def terminate(worker : Worker(T))
      Log.warn &.emit("Terminating Worker", queue: name, worker_id: worker.wid)
      @workers_mutex.synchronize { workers.delete(worker) }
    end

    def restart(worker : Worker(T), ex : Exception)
      terminate worker
      return unless running?
      worker = create_worker
      @workers_mutex.synchronize { workers << worker }
      worker.run
    end

    def info
      result = {
        name:                       name,
        total_workers:              total_workers,
        status:                     status,
        current_size:               size,
        completed:                  completed.get,
        retried:                    retried.get,
        dead:                       dead.get,
        running_workers:            running_workers,
        jobs_completed_per_second:  jobs_completed_per_second,
        queue_reduction_rate:       queue_reduction_rate,
        errors_per_second:          errors_per_second,
        enqueued_per_second:        enqueued_per_second,
        job_wait_time:              job_wait_time,
        job_execution_time:         job_execution_time,
        worker_utilization:         worker_utilization,
        error_rate_trend:           error_rate_trend,
        failed_job_rate:            failed_job_rate,
      }
      result
    end

    private def per_second_rate(count : Int64) : Float64
      total_time = elapsed_time.total_seconds
      return 0.0 if total_time == 0.0
      (count.to_f / total_time).round(2)
    end

    private def percentage_rate(part : Int64, total : Int64) : Float64
      return 0.0 if total == 0
      (part.to_f / total.to_f * 100.0).round(2)
    end

    def elapsed_time : Time::Span
      Time.monotonic - start_time
    end

    private def average_time(total_time : Time::Span, count : Int64) : Float64
      return 0.0 if count.zero?
      avg_time = (total_time / count.to_f)
      avg_time.total_seconds > 1 ? avg_time.total_seconds.round(2) : avg_time.total_milliseconds.round(2)
    end

    private def reprocess_busy_jobs!
      @store.move_job_back_to_queue(name)
    end

    private def create_workers
      total_workers.times { workers << create_worker }
    end

    private def create_worker
      Worker(T).new workers.size, terminate_channel, self
    end
  end
end
