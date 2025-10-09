module JoobQ
  # Error monitoring and alerting system
  class ErrorMonitor
    include JSON::Serializable

    getter error_counts : Hash(String, Int32) = {} of String => Int32
    getter recent_errors : Array(ErrorContext) = [] of ErrorContext
    getter alert_thresholds : Hash(String, Int32) = {
      "error" => 10,
      "warn"  => 50,
      "info"  => 100,
    } of String => Int32
    getter time_window : Time::Span = 5.minutes
    getter max_recent_errors : Int32 = 100
    getter notify_alert : Proc(Hash(String, String), Nil) = ->(_alert_context : Hash(String, String)) { }

    # Redis keys for error storage
    private ERROR_COUNTS_KEY  = "joobq:error_counts"
    private RECENT_ERRORS_KEY = "joobq:recent_errors"
    private ERROR_INDEX_KEY   = "joobq:error_index"

    # Flag to track if Redis data has been loaded
    @redis_loaded : Bool = false

    # Setter methods for configuration
    def alert_thresholds=(thresholds : Hash(String, Int32))
      @alert_thresholds = thresholds
    end

    def time_window=(window : Time::Span)
      @time_window = window
    end

    def max_recent_errors=(max : Int32)
      @max_recent_errors = max
    end

    def notify_alert=(callback : Proc(Hash(String, String), Nil))
      @notify_alert = callback
    end

    def initialize(
      @time_window : Time::Span = 5.minutes,
      @max_recent_errors : Int32 = 100,
      @notify_alert : Proc(Hash(String, String), Nil) = ->(_alert_context : Hash(String, String)) { },
    )
      # Don't load from Redis during initialization to avoid circular dependency
      # Data will be loaded when first accessed
    end

    def record_error(error_context : ErrorContext) : Nil
      # Add to recent errors
      @recent_errors << error_context

      # Store in Redis
      store_error_in_redis(error_context)

      # Trim old errors and decay counts
      trim_old_errors
      decay_error_counts

      # Update error counts
      error_key = "#{error_context.error_type}:#{error_context.queue_name}"
      @error_counts[error_key] = (@error_counts[error_key]? || 0) + 1

      # Invalidate error caches since data has changed
      invalidate_error_caches

      # Check for alerts
      check_alerts(error_context)
    end

    private def invalidate_error_caches : Nil
      # Invalidate error-related caches when new errors are recorded
      JoobQ.api_cache.invalidate_error_stats
      JoobQ.api_cache.invalidate_recent_errors
    rescue ex
      # Don't fail error recording if cache invalidation fails
      Log.warn &.emit("Failed to invalidate error caches", error: ex.message)
    end

    def get_error_stats : Hash(String, Int32)
      # Ensure Redis data is loaded
      ensure_redis_loaded
      @error_counts.dup
    end

    # Get fresh error stats by forcing a reload from Redis
    def get_fresh_error_stats : Hash(String, Int32)
      force_reload_from_redis
      @error_counts.dup
    end

    def get_time_windowed_error_stats : Hash(String, Int32)
      # Ensure Redis data is loaded
      ensure_redis_loaded

      # Get error counts only for errors within the time window
      cutoff_time = Time.local - @time_window
      time_windowed_counts = {} of String => Int32

      @recent_errors.each do |error|
        begin
          error_time = Time.parse(error.occurred_at, "%Y-%m-%dT%H:%M:%S%z", Time::Location::UTC)
          if error_time.to_local >= cutoff_time
            error_key = "#{error.error_type}:#{error.queue_name}"
            time_windowed_counts[error_key] = (time_windowed_counts[error_key]? || 0) + 1
          end
        rescue
          # Skip errors with invalid timestamps
        end
      end

      time_windowed_counts
    end

    def get_recent_errors(limit : Int32 = 20) : Array(ErrorContext)
      # Ensure Redis data is loaded
      ensure_redis_loaded
      @recent_errors.last(limit)
    end

    # Get recent errors with pagination support
    def get_recent_errors_paginated(page : Int32, per_page : Int32) : Array(ErrorContext)
      # Ensure Redis data is loaded
      ensure_redis_loaded

      offset = (page - 1) * per_page
      start_index = [@recent_errors.size - offset - per_page, 0].max
      end_index = [@recent_errors.size - offset - 1, 0].max

      if start_index > end_index
        [] of ErrorContext
      else
        @recent_errors[start_index..end_index].reverse
      end
    end

    # Get total count of recent errors
    def get_recent_errors_count : Int32
      ensure_redis_loaded
      @recent_errors.size
    end

    # Get error information for multiple jobs in batch
    def get_errors_for_jobs_batch(jids : Array(String)) : Hash(String, ErrorContext?)
      ensure_redis_loaded

      results = {} of String => ErrorContext?
      jids.each { |jid| results[jid] = nil }

      # Find errors for each JID in a single pass through recent_errors
      @recent_errors.each do |error|
        if jids.includes?(error.job_id.to_s) && results[error.job_id.to_s].nil?
          results[error.job_id.to_s] = error
        end
      end

      results
    end

    def get_errors_by_type(error_type : String) : Array(ErrorContext)
      # Ensure Redis data is loaded
      ensure_redis_loaded
      @recent_errors.select { |error| error.error_type == error_type }
    end

    def get_errors_by_queue(queue_name : String) : Array(ErrorContext)
      # Ensure Redis data is loaded
      ensure_redis_loaded
      @recent_errors.select { |error| error.queue_name == queue_name }
    end

    def clear_old_errors : Nil
      cutoff_time = Time.local - @time_window
      @recent_errors.reject! { |error|
        begin
          # Parse the timestamp and convert to local time for comparison
          error_time = Time.parse(error.occurred_at, "%Y-%m-%dT%H:%M:%S%z", Time::Location::UTC)
          error_time.to_local < cutoff_time
        rescue
          true
        end
      }
    end

    def reset : Nil
      @error_counts.clear
      @recent_errors.clear
      clear_redis_errors
    end

    private def trim_old_errors : Nil
      # First remove old errors based on time window
      clear_old_errors

      # Then trim if still too many errors - keep the most recent ones
      if @recent_errors.size > @max_recent_errors
        @recent_errors = @recent_errors.last(@max_recent_errors)
      end
    end

    private def decay_error_counts : Nil
      # Remove error counts for errors that are no longer in recent_errors
      # This prevents indefinite growth of error counts
      current_error_keys = Set(String).new

      @recent_errors.each do |error|
        error_key = "#{error.error_type}:#{error.queue_name}"
        current_error_keys.add(error_key)
      end

      # Remove counts for errors that are no longer recent
      @error_counts.reject! { |key, _| !current_error_keys.includes?(key) }
    end

    private def check_alerts(error_context : ErrorContext) : Nil
      error_type = error_context.error_type
      queue_name = error_context.queue_name
      error_key = "#{error_type}:#{queue_name}"

      # Use time-windowed counts for more accurate alerting
      time_windowed_stats = get_time_windowed_error_stats
      current_count = time_windowed_stats[error_key]? || 0
      threshold = @alert_thresholds[error_context.severity]? || 100

      if current_count >= threshold
        send_alert(error_context, current_count, threshold)
      end
    end

    private def send_alert(error_context : ErrorContext, count : Int32, threshold : Int32) : Nil
      # Create alert context for logging (with symbol keys)
      log_context = {
        alert_type:    "error_threshold_exceeded",
        error_type:    error_context.error_type,
        queue_name:    error_context.queue_name,
        current_count: count.to_s,
        threshold:     threshold.to_s,
        severity:      error_context.severity,
        time_window:   @time_window.to_s,
        occurred_at:   Time.local.to_rfc3339,
      }

      # Create alert context for notification callback (with string keys)
      alert_context = {
        "alert_type"    => "error_threshold_exceeded",
        "error_type"    => error_context.error_type,
        "queue_name"    => error_context.queue_name,
        "current_count" => count.to_s,
        "threshold"     => threshold.to_s,
        "severity"      => error_context.severity,
        "time_window"   => @time_window.to_s,
        "occurred_at"   => Time.local.to_rfc3339,
      }

      case error_context.severity
      when "error"
        Log.error &.emit("ERROR ALERT: Threshold exceeded", log_context)
      when "warn"
        Log.warn &.emit("WARNING ALERT: Threshold exceeded", log_context)
      else
        Log.info &.emit("INFO ALERT: Threshold exceeded", log_context)
      end

      # Here you could integrate with external alerting systems
      # like Slack, PagerDuty, email, etc.
      notify_alert.call(alert_context) if notify_alert
    end

    # Redis storage methods
    private def store_error_in_redis(error_context : ErrorContext) : Nil
      store_error_in_redis_pipelined(error_context)
    rescue ex
      Log.warn &.emit("Failed to store error in Redis", error: ex.message)
    end

    private def store_error_in_redis_pipelined(error_context : ErrorContext) : Nil
      store = JoobQ.store.as(RedisStore)
      error_id = "#{error_context.job_id}:#{Time.local.to_unix}"
      timestamp = Time.parse(error_context.occurred_at, "%Y-%m-%dT%H:%M:%S%z", Time::Location::UTC).to_unix
      error_key = "#{error_context.error_type}:#{error_context.queue_name}"

      store.redis.pipelined do |pipe|
        # Store error context
        pipe.hset(RECENT_ERRORS_KEY, error_id, error_context.to_json)
        # Add to time-based index
        pipe.zadd(ERROR_INDEX_KEY, timestamp, error_id)
        # Update error counts
        pipe.hincrby(ERROR_COUNTS_KEY, error_key, 1)
        # Trim old errors (if needed)
        cutoff_time = (Time.local - @time_window).to_unix
        pipe.zremrangebyscore(ERROR_INDEX_KEY, "-inf", cutoff_time)
      end
    end

    def load_errors_from_redis : Nil
      return if @redis_loaded

      perform_redis_load
    end

    # Force reload data from Redis, bypassing the cache
    def force_reload_from_redis : Nil
      @redis_loaded = false
      perform_redis_load
    end

    private def perform_redis_load : Nil
      store = JoobQ.store.as(RedisStore)

      # Load error counts
      error_counts_data = store.redis.hgetall(ERROR_COUNTS_KEY)
      @error_counts.clear
      error_counts_data.each do |key, value|
        @error_counts[key] = value.to_i
      end

      # Load recent errors
      @recent_errors.clear
      error_ids = store.redis.zrange(ERROR_INDEX_KEY, 0, -1)
      error_ids.each do |error_id|
        error_json = store.redis.hget(RECENT_ERRORS_KEY, error_id)
        if error_json
          begin
            error_context = ErrorContext.from_json(error_json)
            @recent_errors << error_context
          rescue ex
            Log.warn &.emit("Failed to parse error from Redis", error_id: error_id, error: ex.message)
          end
        end
      end

      # Sort by occurred_at timestamp
      @recent_errors.sort_by!(&.occurred_at)

      @redis_loaded = true
      Log.debug &.emit("Loaded #{@recent_errors.size} errors from Redis")
    rescue ex
      Log.warn &.emit("Failed to load errors from Redis", error: ex.message)
      @redis_loaded = true # Mark as loaded even if failed to avoid retrying

    end

    private def ensure_redis_loaded : Nil
      load_errors_from_redis unless @redis_loaded
    end

    def clear_redis_errors : Nil
      store = JoobQ.store.as(RedisStore)
      store.redis.del(ERROR_COUNTS_KEY, RECENT_ERRORS_KEY, ERROR_INDEX_KEY)
    rescue ex
      Log.warn &.emit("Failed to clear Redis errors", error: ex.message)
    end

    # Batch error storage for improved performance
    def store_errors_batch(error_contexts : Array(ErrorContext)) : Nil
      return if error_contexts.empty?

      begin
        store_errors_batch_pipelined(error_contexts)
      rescue ex
        Log.warn &.emit("Failed to store error batch in Redis", error: ex.message)
      end
    end

    private def store_errors_batch_pipelined(error_contexts : Array(ErrorContext)) : Nil
      store = JoobQ.store.as(RedisStore)
      cutoff_time = (Time.local - @time_window).to_unix

      # Track pipeline operation
      commands_count = (error_contexts.size * 3) + 1 # 3 commands per error + cleanup
      success = false

      begin
        store.redis.pipelined do |pipe|
          error_contexts.each do |error_context|
            error_id = "#{error_context.job_id}:#{Time.local.to_unix}"
            timestamp = Time.parse(error_context.occurred_at, "%Y-%m-%dT%H:%M:%S%z", Time::Location::UTC).to_unix
            error_key = "#{error_context.error_type}:#{error_context.queue_name}"

            # Store error context
            pipe.hset(RECENT_ERRORS_KEY, error_id, error_context.to_json)
            # Add to time-based index
            pipe.zadd(ERROR_INDEX_KEY, timestamp, error_id)
            # Update error counts
            pipe.hincrby(ERROR_COUNTS_KEY, error_key, 1)
          end

          # Batch cleanup old errors
          pipe.zremrangebyscore(ERROR_INDEX_KEY, "-inf", cutoff_time)
        end
        success = true
      ensure
        store.track_pipeline_operation(commands_count, success)
      end
    end
  end

  # Enhanced error handler that integrates with monitoring
  module MonitoredErrorHandler
    def self.handle_job_error(
      job : Job,
      queue : BaseQueue,
      exception : Exception,
      worker_id : String,
      retry_count : Int32 = 0,
      additional_context : Hash(String, String) = {} of String => String,
    ) : ErrorContext
      # Create error context using ErrorHandler
      error_context = ErrorHandler.handle_job_error(job, queue, exception, worker_id, retry_count, additional_context)

      # Record in error monitor
      JoobQ.error_monitor.record_error(error_context)

      error_context
    end
  end
end
