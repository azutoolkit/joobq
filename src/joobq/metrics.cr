module JoobQ
  class Metrics
    getter completed : Atomic(Int64) = Atomic(Int64).new(0)
    getter retried : Atomic(Int64) = Atomic(Int64).new(0)
    getter dead : Atomic(Int64) = Atomic(Int64).new(0)
    getter busy : Atomic(Int64) = Atomic(Int64).new(0)
    property total_job_wait_time : Time::Span = Time::Span.zero
    property total_job_execution_time : Time::Span = Time::Span.zero
    property last_queue_size : Int64 = 0_i64
    property last_queue_time : Time::Span = Time.monotonic
    property start_time : Time::Span = Time.monotonic

    # Provides thread-safe methods to update metrics
    def increment_completed
      completed.add(1)
    end

    def increment_retried
      retried.add(1)
    end

    def increment_dead
      dead.add(1)
    end

    def increment_busy
      busy.add(1)
    end

    def decrement_busy
      busy.sub(1)
    end

    def add_job_wait_time(wait_time : Time::Span)
      @total_job_wait_time += wait_time
    end

    def add_job_execution_time(execution_time : Time::Span)
      @total_job_execution_time += execution_time
    end

    # Calculate elapsed time since the start of the queue
    # This is used to calculate rates per second for metrics
    def elapsed_time : Time::Span
      Time.monotonic - start_time
    end

    # Metric calculations
    def jobs_completed_per_second : Float64
      per_second_rate(completed.get)
    end

    # Calculate the rate at which jobs are being enqueued per second for the queue
    # This is used to calculate the rate at which the queue is being reduced in size
    def errors_per_second : Float64
      per_second_rate(retried.get)
    end

    # Calculate the rate at which the queue is being reduced in size per second
    def queue_reduction_rate(current_queue_size : Int64) : Float64
      current_time = Time.monotonic
      time_delta = current_time - last_queue_time
      return 0.0 if time_delta.total_seconds == 0.0

      size_delta = last_queue_size - current_queue_size

      reduction_rate = size_delta.to_f / time_delta.total_seconds

      @last_queue_size = current_queue_size
      @last_queue_time = current_time

      reduction_rate.round(2)
    end

    def job_wait_time : Float64
      average_time(total_job_wait_time, completed.get)
    end

    def job_execution_time : Float64
      average_time(total_job_execution_time, completed.get)
    end

    # Calculate the utilization of workers in the queue based on the total time spent processing jobs
    # This is used to determine how efficiently workers are being utilized in the queue
    # Utilization is calculated as the percentage of time spent processing jobs compared to the total time workers have
    # been active in the queue since the start
    def worker_utilization(total_workers : Int32) : Float64
      total_worker_time = total_workers.to_f * elapsed_time.total_seconds
      return 0.0 if total_worker_time == 0.0
      utilization = (total_job_execution_time.total_seconds / total_worker_time) * 100.0
      utilization.clamp(0.0, 100.0).round(2)
    end

    # Calculate the error rate trend for the queue
    # This is used to determine the trend of errors in the queue over time
    # The error rate trend is calculated as the percentage of retried jobs compared to the total number of attempted jobs
    def error_rate_trend : Float64
      total_attempted_jobs = completed.get + retried.get + dead.get
      percentage_rate(retried.get, total_attempted_jobs)
    end

    # Calculate the rate of failed jobs in the queue
    # This is used to determine the rate of jobs that have failed to be processed in the queue
    # The failed job rate is calculated as the percentage of dead jobs compared to the total number of processed jobs
    def failed_job_rate : Float64
      total_processed_jobs = completed.get + dead.get
      percentage_rate(dead.get, total_processed_jobs)
    end

    # Calculate the average number of jobs in flight in the queue
    def average_jobs_in_flight : Float64
      elapsed = elapsed_time.total_seconds
      return 0.0 if elapsed == 0.0
      avg_in_flight = total_job_execution_time.total_seconds / elapsed
      avg_in_flight.round(2)
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

    private def average_time(total_time : Time::Span, count : Int64) : Float64
      return 0.0 if count.zero?
      avg_time = (total_time / count.to_f)
      avg_time.total_seconds > 1 ? avg_time.total_seconds.round(2) : avg_time.total_milliseconds.round(2)
    end
  end
end