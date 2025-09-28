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

    # Redis keys for error storage
    private ERROR_COUNTS_KEY = "joobq:error_counts"
    private RECENT_ERRORS_KEY = "joobq:recent_errors"
    private ERROR_INDEX_KEY = "joobq:error_index"

    # Flag to track if Redis data has been loaded
    @redis_loaded : Bool = false

    def initialize
    end

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

    def initialize(@time_window : Time::Span = 5.minutes, @max_recent_errors : Int32 = 100)
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

      # Update Redis error counts
      update_redis_error_counts(error_key)

      # Check for alerts
      check_alerts(error_context)
    end

    def get_error_stats : Hash(String, Int32)
      # Ensure Redis data is loaded
      ensure_redis_loaded
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

    # Redis storage methods
    private def store_error_in_redis(error_context : ErrorContext) : Nil
      begin
        store = JoobQ.store.as(RedisStore)
        error_id = "#{error_context.job_id}:#{Time.local.to_unix}"

        # Store error context as JSON
        store.redis.hset(RECENT_ERRORS_KEY, error_id, error_context.to_json)

        # Add to sorted set for time-based queries (score = timestamp)
        timestamp = Time.parse(error_context.occurred_at, "%Y-%m-%dT%H:%M:%S%z", Time::Location::UTC).to_unix
        store.redis.zadd(ERROR_INDEX_KEY, timestamp, error_id)

        # Trim old errors from Redis
        trim_redis_errors
      rescue ex
        Log.warn &.emit("Failed to store error in Redis", error: ex.message)
      end
    end

    private def update_redis_error_counts(error_key : String) : Nil
      begin
        store = JoobQ.store.as(RedisStore)
        store.redis.hincrby(ERROR_COUNTS_KEY, error_key, 1)
      rescue ex
        Log.warn &.emit("Failed to update Redis error counts", error: ex.message)
      end
    end

    private def trim_redis_errors : Nil
      begin
        store = JoobQ.store.as(RedisStore)
        cutoff_time = (Time.local - @time_window).to_unix

        # Remove old errors from sorted set
        store.redis.zremrangebyscore(ERROR_INDEX_KEY, "-inf", cutoff_time)

        # Get current error IDs from sorted set
        error_ids = store.redis.zrange(ERROR_INDEX_KEY, 0, -1)

        # If we have too many errors, remove the oldest ones
        if error_ids.size > @max_recent_errors
          excess_count = error_ids.size - @max_recent_errors
          oldest_ids = error_ids[0...excess_count]

          # Remove oldest errors from hash
          oldest_ids.each do |error_id|
            store.redis.hdel(RECENT_ERRORS_KEY, error_id)
          end

          # Remove from sorted set
          store.redis.zremrangebyrank(ERROR_INDEX_KEY, 0, excess_count - 1)
        end
      rescue ex
        Log.warn &.emit("Failed to trim Redis errors", error: ex.message)
      end
    end

    def load_errors_from_redis : Nil
      return if @redis_loaded

      begin
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
        @recent_errors.sort_by! { |error| error.occurred_at }


        @redis_loaded = true
      rescue ex
        Log.warn &.emit("Failed to load errors from Redis", error: ex.message)
        @redis_loaded = true # Mark as loaded even if failed to avoid retrying
      end
    end

    private def ensure_redis_loaded : Nil
      load_errors_from_redis unless @redis_loaded
    end

    def clear_redis_errors : Nil
      begin
        store = JoobQ.store.as(RedisStore)
        store.redis.del(ERROR_COUNTS_KEY, RECENT_ERRORS_KEY, ERROR_INDEX_KEY)
      rescue ex
        Log.warn &.emit("Failed to clear Redis errors", error: ex.message)
      end
    end
  end


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
