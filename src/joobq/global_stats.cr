module JoobQ
  # Interface for metrics providers
  module MetricsProvider
    abstract def global_metrics : Hash(String, Int64 | Float64)
  end

  # Utility module for common statistical calculations
  module StatsUtils
    def self.percent_of(value : Number, total : Number) : Float64
      if total.to_f == 0 || value.to_f <= 0
        0.0
      else
        percentage = (value.to_f / total.to_f * 100)
        percentage = 100.0 if percentage > 100.0 # Optional: Cap at 100%
        percentage.round(2)
      end
    end

    def self.format_latency(latency_in_seconds : Float64) : String
      if latency_in_seconds >= 1
        "#{latency_in_seconds.round(2)}s"
      else
        "#{(latency_in_seconds * 1000).round(2)}ms"
      end
    end
  end

  # Class to handle overtime series data
  class OvertimeSeries
    alias SeriesData = Array(NamedTuple(x: String, y: Float64 | Int64))
    alias Series = NamedTuple(name: String, type: String, data: SeriesData)

    property overtime_series : Array(Series) = [] of Series

    def initialize
      @overtime_series << {name: "Enqueued", type: "column", data: SeriesData.new(10)}
      @overtime_series << {name: "Completed", type: "line", data: SeriesData.new(10)}
    end

    def update(enqueued : Float64, jobs_completed_per_second : Float64)
      current_time = Time.local.to_rfc3339
      enqueued_series = @overtime_series.first
      completed_series = @overtime_series.last

      enqueued_series[:data] << {x: current_time, y: enqueued}
      completed_series[:data] << {x: current_time, y: jobs_completed_per_second}

      enqueued_series[:data].shift if enqueued_series[:data].size > 10
      completed_series[:data].shift if completed_series[:data].size > 10
    end
  end

  # Class to aggregate global statistics
  class GlobalStats
    include StatsUtils

    def self.instance
      @@instance ||= new
    end

    # Define properties for all the stats
    property total_workers : Int64 = 0
    property current_size : Int64 = 0
    property total_jobs : Int64 = 0
    property completed : Int64 = 0
    property retried : Int64 = 0
    property dead : Int64 = 0
    property processing : Int64 = 0
    property running_workers : Int64 = 0
    property jobs_completed_per_second : Float64 = 0.0
    property errors_per_second : Float64 = 0.0
    property enqueued_per_second : Float64 = 0.0
    property job_wait_time : Float64 = 0.0
    property job_execution_time : Float64 = 0.0
    property worker_utilization : Float64 = 0.0
    property error_rate_trend : Float64 = 0.0
    property failed_job_rate : Float64 = 0.0
    property jobs_per_worker_per_second : Float64 = 0.0

    property overtime_series : OvertimeSeries

    def initialize(@metrics_provider : MetricsProvider = QueueMetrics.instance)
      reset
      @overtime_series = OvertimeSeries.new
    end

    # Calculate global statistics using a metrics provider
    def calculate_stats
      reset
      global_metrics = @metrics_provider.global_metrics

      @total_workers = global_metrics["total_workers"].to_i64
      @current_size = global_metrics["current_size"].to_i64
      @total_jobs = global_metrics["total_jobs"].to_i64
      @completed = global_metrics["completed"].to_i64
      @retried = global_metrics["retried"].to_i64
      @dead = global_metrics["dead"].to_i64
      @processing = global_metrics["processing"].to_i64
      @running_workers = global_metrics["running_workers"].to_i64
      @jobs_completed_per_second = global_metrics["jobs_completed_per_second"].to_f64
      @errors_per_second = global_metrics["errors_per_second"].to_f64
      @enqueued_per_second = global_metrics["enqueued_per_second"].to_f64
      @job_wait_time = global_metrics["job_wait_time"].to_f64
      @job_execution_time = global_metrics["job_execution_time"].to_f64
      @worker_utilization = global_metrics["worker_utilization"].to_f64
      @error_rate_trend = global_metrics["error_rate_trend"].to_f64
      @failed_job_rate = global_metrics["failed_job_rate"].to_f64
      @jobs_per_worker_per_second = global_metrics["jobs_per_worker_per_second"].to_f64

      update_overtime_series
      stats
    end

    private def reset
      @total_workers = 0
      @current_size = 0
      @total_jobs = 0
      @completed = 0
      @retried = 0
      @dead = 0
      @processing = 0
      @running_workers = 0
      @jobs_completed_per_second = 0.0
      @errors_per_second = 0.0
      @enqueued_per_second = 0.0
      @job_wait_time = 0.0
      @job_execution_time = 0.0
      @worker_utilization = 0.0
      @error_rate_trend = 0.0
      @failed_job_rate = 0.0
      @jobs_per_worker_per_second = 0.0
    end

    private def update_overtime_series
      @overtime_series.update(@enqueued_per_second, @jobs_completed_per_second)
    end

    def stats
      {
        "total_workers"              => @total_workers,
        "current_size"               => @current_size,
        "total_jobs"                 => @total_jobs,
        "completed"                  => @completed,
        "retried"                    => @retried,
        "dead"                       => @dead,
        "processing"                 => @processing,
        "running_workers"            => @running_workers,
        "jobs_completed_per_second"  => @jobs_completed_per_second.round(2),
        "errors_per_second"          => @errors_per_second.round(2),
        "enqueued_per_second"        => @enqueued_per_second.round(2),
        "job_wait_time"              => @job_wait_time,
        "job_execution_time"         => @job_execution_time,
        "worker_utilization"         => @worker_utilization.round(2),
        "error_rate_trend"           => @error_rate_trend.round(2),
        "failed_job_rate"            => @failed_job_rate.round(2),
        "jobs_per_worker_per_second" => @jobs_per_worker_per_second.round(2),
        "percent_pending"            => StatsUtils.percent_of(@total_jobs - @completed, @total_jobs),
        "percent_processing"         => StatsUtils.percent_of(@processing, @total_jobs),
        "percent_completed"          => StatsUtils.percent_of(@completed, @total_jobs),
        "percent_retried"            => StatsUtils.percent_of(@retried, @total_jobs),
        "percent_dead"               => StatsUtils.percent_of(@dead, @total_jobs),
        "overtime_series"            => @overtime_series.overtime_series,
      }
    end
  end
end
