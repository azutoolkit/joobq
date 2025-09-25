module JoobQ
  # Comprehensive error context system for better error handling and debugging
  class ErrorContext
    include JSON::Serializable

    getter job_id : String
    getter queue_name : String
    getter worker_id : String?
    getter job_type : String
    getter error_type : String
    getter error_message : String
    getter error_class : String
    getter backtrace : Array(String)
    getter occurred_at : String
    getter retry_count : Int32
    getter job_data : String?
    getter system_context : Hash(String, String)
    getter error_cause : String?

    def initialize(
      @job_id : String,
      @queue_name : String,
      @job_type : String,
      @error_type : String,
      @error_message : String,
      @error_class : String,
      @backtrace : Array(String),
      @retry_count : Int32 = 0,
      @job_data : String? = nil,
      @worker_id : String? = nil,
      @error_cause : String? = nil,
      @system_context : Hash(String, String) = {} of String => String,
      @occurred_at : String = Time.local.to_rfc3339,
    )
    end

    def self.from_exception(
      job : Job,
      queue : BaseQueue,
      exception : Exception,
      worker_id : String? = nil,
      retry_count : Int32 = 0,
      additional_context : Hash(String, String) = {} of String => String,
    ) : ErrorContext
      error_type = classify_error(exception)

      new(
        job_id: job.jid.to_s,
        queue_name: queue.name,
        job_type: job.class.name,
        error_type: error_type,
        error_message: exception.message || "Unknown error",
        error_class: exception.class.name,
        backtrace: extract_backtrace(exception),
        retry_count: retry_count,
        job_data: job.to_json,
        worker_id: worker_id,
        error_cause: exception.cause.try(&.message),
        system_context: build_system_context(queue, additional_context),
        occurred_at: Time.local.to_rfc3339
      )
    end

    def self.classify_error(exception : Exception) : String
      case exception
      when ArgumentError
        "validation_error"
      when Socket::ConnectError, Redis::CannotConnectError
        "connection_error"
      when IO::TimeoutError
        "timeout_error"
      when JSON::Error
        "serialization_error"
      when KeyError
        "configuration_error"
      when NotImplementedError
        "implementation_error"
      else
        "unknown_error"
      end
    end

    def self.extract_backtrace(exception : Exception) : Array(String)
      exception.inspect_with_backtrace
        .split('\n')
        .first(20) # Limit to first 20 lines
        .map(&.strip)
    end

    def self.build_system_context(queue : BaseQueue, additional : Hash(String, String)) : Hash(String, String)
      context = {
        "queue_workers"         => queue.total_workers.to_s,
        "queue_running_workers" => queue.running_workers.to_s,
        "system_time"           => Time.local.to_rfc3339,
        "memory_usage"          => get_memory_usage,
      }

      # Try to get queue size, but don't fail if Redis is not available
      begin
        context["queue_size"] = queue.size.to_s
      rescue
        context["queue_size"] = "unknown"
      end

      additional.each do |key, value|
        context[key] = value
      end

      context
    end

    def self.get_memory_usage : String
      # Simple memory usage estimation
      GC.stats.total_bytes.to_s
    rescue
      "unknown"
    end

    def to_log_context : Hash(Symbol, String)
      {
        job_id:      job_id,
        queue:       queue_name,
        job_type:    job_type,
        error_type:  error_type,
        error_class: error_class,
        retry_count: retry_count.to_s,
        worker_id:   worker_id || "unknown",
        occurred_at: occurred_at,
      }.to_h
    end

    def should_retry? : Bool
      case error_type
      when "validation_error", "configuration_error", "implementation_error"
        false
      when "connection_error", "timeout_error"
        retry_count < 3
      else
        retry_count < 5
      end
    end

    def retry_delay : Time::Span
      case error_type
      when "connection_error"
        (2 ** retry_count).seconds
      when "timeout_error"
        (retry_count + 1).seconds
      else
        (2 ** retry_count).seconds
      end
    end

    def severity : String
      case error_type
      when "validation_error", "configuration_error"
        "error"
      when "connection_error", "timeout_error"
        "warn"
      when "implementation_error"
        "error"
      else
        "error"
      end
    end
  end

  # Error classification and handling utilities
  module ErrorHandler
    def self.handle_job_error(
      job : Job,
      queue : BaseQueue,
      exception : Exception,
      worker_id : String? = nil,
      retry_count : Int32 = 0,
      additional_context : Hash(String, String) = {} of String => String,
    ) : ErrorContext
      error_context = ErrorContext.from_exception(
        job, queue, exception, worker_id, retry_count, additional_context
      )

      # Log the error with rich context
      log_error(error_context)

      # Update job with error information
      update_job_with_error(job, error_context)

      # Handle retry or dead letter based on error type
      if error_context.should_retry?
        schedule_retry(job, queue, error_context)
      else
        send_to_dead_letter(job, queue, error_context)
      end

      error_context
    end

    def self.log_error(error_context : ErrorContext) : Nil
      case error_context.severity
      when "error"
        Log.error &.emit("Job processing failed: #{error_context.error_message}", error_context.to_log_context)
      when "warn"
        Log.warn &.emit("Job processing failed: #{error_context.error_message}", error_context.to_log_context)
      else
        Log.info &.emit("Job processing failed: #{error_context.error_message}", error_context.to_log_context)
      end
    end

    def self.update_job_with_error(job : Job, error_context : ErrorContext) : Nil
      job.failed!
      job.retries = job.retries - 1

      job.error = {
        failed_at:      error_context.occurred_at,
        message:        error_context.error_message,
        backtrace:      error_context.backtrace.join("\n"),
        cause:          error_context.error_cause || "",
        error_type:     error_context.error_type,
        error_class:    error_context.error_class,
        retry_count:    error_context.retry_count,
        system_context: error_context.system_context,
      }
    end

    def self.schedule_retry(job : Job, queue : BaseQueue, error_context : ErrorContext) : Nil
      job.retrying!
      delay = error_context.retry_delay

      Log.info &.emit(
        "Scheduling job retry",
        job_id: job.jid.to_s,
        queue: queue.name,
        delay: delay.to_s,
        retry_count: error_context.retry_count + 1,
        error_type: error_context.error_type
      )

      queue.store.schedule(job, delay.total_milliseconds.to_i64, delay_set: RedisStore::FAILED_SET)
    end

    def self.send_to_dead_letter(job : Job, queue : BaseQueue, error_context : ErrorContext) : Nil
      Log.error &.emit(
        "Sending job to dead letter queue",
        job_id: job.jid.to_s,
        queue: queue.name,
        error_type: error_context.error_type,
        retry_count: error_context.retry_count
      )

      begin
        DeadLetterManager.add(job)
      rescue ex
        Log.error &.emit(
          "Failed to send job to dead letter queue",
          job_id: job.jid.to_s,
          queue: queue.name,
          error: ex.message || "Unknown error"
        )
      end
    end
  end
end
