module JoobQ
  # Error monitoring and alerting system
  class ErrorMonitor
    include JSON::Serializable

    getter error_counts : Hash(String, Int32) = {} of String => Int32
    getter recent_errors : Array(ErrorContext) = [] of ErrorContext
    getter alert_thresholds : Hash(String, Int32) = {
      "error" => 10,
      "warn" => 50,
      "info" => 100
    } of String => Int32
    getter time_window : Time::Span = 5.minutes
    getter max_recent_errors : Int32 = 100

    def initialize(@time_window : Time::Span = 5.minutes, @max_recent_errors : Int32 = 100)
    end

    def record_error(error_context : ErrorContext) : Nil
      # Add to recent errors
      @recent_errors << error_context

      # Trim old errors
      trim_old_errors

      # Update error counts
      error_key = "#{error_context.error_type}:#{error_context.queue_name}"
      @error_counts[error_key] = (@error_counts[error_key]? || 0) + 1

      # Check for alerts
      check_alerts(error_context)
    end

    def get_error_stats : Hash(String, Int32)
      @error_counts.dup
    end

    def get_recent_errors(limit : Int32 = 20) : Array(ErrorContext)
      @recent_errors.last(limit)
    end

    def get_errors_by_type(error_type : String) : Array(ErrorContext)
      @recent_errors.select { |error| error.error_type == error_type }
    end

    def get_errors_by_queue(queue_name : String) : Array(ErrorContext)
      @recent_errors.select { |error| error.queue_name == queue_name }
    end

    def clear_old_errors : Nil
      cutoff_time = Time.local - @time_window
      @recent_errors.reject! { |error|
        begin
          Time.parse(error.occurred_at, "%Y-%m-%dT%H:%M:%S%z", Time::Location::UTC) < cutoff_time
        rescue
          true
        end
      }
    end

    def reset : Nil
      @error_counts.clear
      @recent_errors.clear
    end

    private def trim_old_errors : Nil
      # First remove old errors based on time window
      clear_old_errors

      # Then trim if still too many errors
      if @recent_errors.size > @max_recent_errors
        @recent_errors = @recent_errors.last(@max_recent_errors)
      end
    end

    private def check_alerts(error_context : ErrorContext) : Nil
      error_type = error_context.error_type
      queue_name = error_context.queue_name
      error_key = "#{error_type}:#{queue_name}"

      current_count = @error_counts[error_key]? || 0
      threshold = @alert_thresholds[error_context.severity]? || 100

      if current_count >= threshold
        send_alert(error_context, current_count, threshold)
      end
    end

    private def send_alert(error_context : ErrorContext, count : Int32, threshold : Int32) : Nil
      alert_context = {
        alert_type: "error_threshold_exceeded",
        error_type: error_context.error_type,
        queue_name: error_context.queue_name,
        current_count: count.to_s,
        threshold: threshold.to_s,
        severity: error_context.severity,
        time_window: @time_window.to_s,
        occurred_at: Time.local.to_rfc3339
      }

      case error_context.severity
      when "error"
        Log.error &.emit("ERROR ALERT: Threshold exceeded", alert_context)
      when "warn"
        Log.warn &.emit("WARNING ALERT: Threshold exceeded", alert_context)
      else
        Log.info &.emit("INFO ALERT: Threshold exceeded", alert_context)
      end

      # Here you could integrate with external alerting systems
      # like Slack, PagerDuty, email, etc.
    end
  end

  # Global error monitor instance
  class_getter error_monitor : ErrorMonitor = ErrorMonitor.new

  # Enhanced error handler that integrates with monitoring
  module MonitoredErrorHandler
    def self.handle_job_error(
      job : Job,
      queue : BaseQueue,
      exception : Exception,
      worker_id : String? = nil,
      retry_count : Int32 = 0,
      additional_context : Hash(String, String) = {} of String => String
    ) : ErrorContext
      # Create error context using ErrorHandler
      error_context = ErrorHandler.handle_job_error(job, queue, exception, worker_id, retry_count, additional_context)

      # Record in error monitor
      JoobQ.error_monitor.record_error(error_context)

      error_context
    end
  end
end
