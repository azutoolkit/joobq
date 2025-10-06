module JoobQ
  class ConfigValidationError < Exception
  end

  # Validates YAML configuration schema and values
  class ConfigValidator
    def self.validate(yaml_data : YAML::Any) : Nil
      # Validate required top-level structure
      unless yaml_data["joobq"]?
        raise ConfigValidationError.new("Missing 'joobq' root key")
      end

      joobq_config = yaml_data["joobq"]

      # Validate settings if present
      if settings = joobq_config["settings"]?
        validate_settings(settings)
      end

      # Validate queues if present
      if queues = joobq_config["queues"]?
        validate_queues(queues)
      end

      # Validate middlewares if present
      if middlewares = joobq_config["middlewares"]?
        validate_middlewares(middlewares)
      end

      # Validate error monitoring if present
      if error_monitoring = joobq_config["error_monitoring"]?
        validate_error_monitoring(error_monitoring)
      end

      # Validate schedulers if present
      if schedulers = joobq_config["schedulers"]?
        validate_schedulers(schedulers)
      end

      # Validate Redis config if present
      if redis_config = joobq_config["redis"]?
        validate_redis_config(redis_config)
      end

      # Validate pipeline config if present
      if pipeline_config = joobq_config["pipeline"]?
        validate_pipeline_config(pipeline_config)
      end

      # Validate features if present
      if features = joobq_config["features"]?
        validate_features(features)
      end
    end

    private def self.validate_settings(settings : YAML::Any)
      # Validate time span formats
      if expires = settings["expires"]?
        validate_time_span(expires.as_s)
      end

      if timeout = settings["timeout"]?
        validate_time_span(timeout.as_s)
      end

      if failed_ttl = settings["failed_ttl"]?
        validate_time_span(failed_ttl.as_s)
      end

      if dead_letter_ttl = settings["dead_letter_ttl"]?
        validate_time_span(dead_letter_ttl.as_s)
      end

      if timezone = settings["timezone"]?
        validate_timezone(timezone.as_s)
      end

      # Validate numeric ranges
      if retries = settings["retries"]?
        retries_value = retries.as_i
        raise ConfigValidationError.new("retries must be >= 0") if retries_value < 0
      end

      if worker_batch_size = settings["worker_batch_size"]?
        batch_size = worker_batch_size.as_i
        raise ConfigValidationError.new("worker_batch_size must be > 0") if batch_size <= 0
      end

      # Validate string fields
      if default_queue = settings["default_queue"]?
        queue_name = default_queue.as_s
        raise ConfigValidationError.new("default_queue cannot be empty") if queue_name.empty?
      end
    end

    private def self.validate_queues(queues : YAML::Any)
      unless queues.as_h?
        raise ConfigValidationError.new("queues must be a hash")
      end

      queues.as_h.each do |queue_name, queue_config|
        # Validate queue name
        if queue_name.as_s.empty?
          raise ConfigValidationError.new("Queue name cannot be empty")
        end

        # Validate required fields
        unless queue_config["job_class"]?
          raise ConfigValidationError.new("Queue '#{queue_name.as_s}' missing required 'job_class'")
        end

        unless queue_config["workers"]?
          raise ConfigValidationError.new("Queue '#{queue_name.as_s}' missing required 'workers'")
        end

        workers = queue_config["workers"].as_i
        raise ConfigValidationError.new("Queue '#{queue_name.as_s}' workers must be > 0") if workers <= 0

        # Validate job class name
        job_class = queue_config["job_class"].as_s
        raise ConfigValidationError.new("Queue '#{queue_name.as_s}' job_class cannot be empty") if job_class.empty?

        # Validate throttle if present
        if throttle = queue_config["throttle"]?
          validate_throttle(throttle, queue_name.as_s)
        end
      end
    end

    private def self.validate_middlewares(middlewares : YAML::Any)
      unless middlewares.as_a?
        raise ConfigValidationError.new("middlewares must be an array")
      end

      valid_types = ["throttle", "retry", "timeout"]

      middlewares.as_a.each do |middleware_config|
        unless middleware_config["type"]?
          raise ConfigValidationError.new("Middleware missing required 'type' field")
        end

        type = middleware_config["type"].as_s
        unless valid_types.includes?(type)
          raise ConfigValidationError.new("Unknown middleware type: #{type}. Valid types: #{valid_types.join(", ")}")
        end
      end
    end

    private def self.validate_error_monitoring(error_monitoring : YAML::Any)
      if time_window = error_monitoring["time_window"]?
        validate_time_span(time_window.as_s)
      end

      if max_recent_errors = error_monitoring["max_recent_errors"]?
        max_errors = max_recent_errors.as_i
        raise ConfigValidationError.new("max_recent_errors must be > 0") if max_errors <= 0
      end

      if alert_thresholds = error_monitoring["alert_thresholds"]?
        unless alert_thresholds.as_h?
          raise ConfigValidationError.new("alert_thresholds must be a hash")
        end

        alert_thresholds.as_h.each do |level, threshold|
          threshold_value = threshold.as_i
          raise ConfigValidationError.new("Alert threshold for '#{level}' must be > 0") if threshold_value <= 0
        end

        # Validate alert level names
        valid_levels = ["error", "warn", "info"]
        alert_thresholds.as_h.each do |level, _|
          unless valid_levels.includes?(level.as_s)
            raise ConfigValidationError.new("Invalid alert level: #{level}. Valid levels: #{valid_levels.join(", ")}")
          end
        end
      end
    end

    private def self.validate_schedulers(schedulers : YAML::Any)
      unless schedulers.as_a?
        raise ConfigValidationError.new("schedulers must be an array")
      end

      schedulers.as_a.each do |scheduler_config|
        if timezone = scheduler_config["timezone"]?
          validate_timezone(timezone.as_s)
        end

        if cron_jobs = scheduler_config["cron_jobs"]?
          validate_cron_jobs(cron_jobs)
        end

        if recurring_jobs = scheduler_config["recurring_jobs"]?
          validate_recurring_jobs(recurring_jobs)
        end

        # At least one job type should be present
        unless scheduler_config["cron_jobs"]? || scheduler_config["recurring_jobs"]?
          raise ConfigValidationError.new("Scheduler must have at least one of 'cron_jobs' or 'recurring_jobs'")
        end
      end
    end

    private def self.validate_cron_jobs(cron_jobs : YAML::Any)
      unless cron_jobs.as_a?
        raise ConfigValidationError.new("cron_jobs must be an array")
      end

      cron_jobs.as_a.each do |cron_job|
        unless cron_job["pattern"]?
          raise ConfigValidationError.new("Cron job missing required 'pattern' field")
        end

        unless cron_job["job"]?
          raise ConfigValidationError.new("Cron job missing required 'job' field")
        end

        # Validate cron pattern format
        pattern = cron_job["pattern"].as_s
        validate_cron_pattern(pattern)

        # Validate job class name
        job_class = cron_job["job"].as_s
        raise ConfigValidationError.new("Cron job 'job' field cannot be empty") if job_class.empty?

        # Validate args if present
        if args = cron_job["args"]?
          unless args.as_h?
            raise ConfigValidationError.new("Cron job 'args' must be a hash")
          end
        end
      end
    end

    private def self.validate_recurring_jobs(recurring_jobs : YAML::Any)
      unless recurring_jobs.as_a?
        raise ConfigValidationError.new("recurring_jobs must be an array")
      end

      recurring_jobs.as_a.each do |recurring_job|
        unless recurring_job["interval"]?
          raise ConfigValidationError.new("Recurring job missing required 'interval' field")
        end

        unless recurring_job["job"]?
          raise ConfigValidationError.new("Recurring job missing required 'job' field")
        end

        interval = recurring_job["interval"].as_s
        validate_time_span(interval)

        # Validate job class name
        job_class = recurring_job["job"].as_s
        raise ConfigValidationError.new("Recurring job 'job' field cannot be empty") if job_class.empty?

        # Validate args if present
        if args = recurring_job["args"]?
          unless args.as_h?
            raise ConfigValidationError.new("Recurring job 'args' must be a hash")
          end
        end
      end
    end

    private def self.validate_redis_config(redis_config : YAML::Any)
      if host = redis_config["host"]?
        host_value = host.as_s
        raise ConfigValidationError.new("Redis host cannot be empty") if host_value.empty?
      end

      if port = redis_config["port"]?
        port_value = port.as_i
        raise ConfigValidationError.new("Redis port must be between 1 and 65535") if port_value < 1 || port_value > 65535
      end

      if pool_size = redis_config["pool_size"]?
        pool_size_value = pool_size.as_i
        raise ConfigValidationError.new("Redis pool_size must be > 0") if pool_size_value <= 0
      end

      if pool_timeout = redis_config["pool_timeout"]?
        timeout_value = pool_timeout.as_f
        raise ConfigValidationError.new("Redis pool_timeout must be > 0") if timeout_value <= 0
      end
    end

    private def self.validate_pipeline_config(pipeline_config : YAML::Any)
      if batch_size = pipeline_config["batch_size"]?
        batch_size_value = batch_size.as_i
        raise ConfigValidationError.new("Pipeline batch_size must be > 0") if batch_size_value <= 0
      end

      if timeout = pipeline_config["timeout"]?
        timeout_value = timeout.as_f
        raise ConfigValidationError.new("Pipeline timeout must be > 0") if timeout_value <= 0
      end

      if max_commands = pipeline_config["max_commands"]?
        max_commands_value = max_commands.as_i
        raise ConfigValidationError.new("Pipeline max_commands must be > 0") if max_commands_value <= 0
      end
    end

    private def self.validate_features(features : YAML::Any)
      # Features validation is straightforward - just check types
      # No additional validation needed for boolean flags
      # Note: YAML boolean validation is complex, so we'll skip strict validation for now
    end

    private def self.validate_time_span(time_str : String)
      unless time_str.match(/^(\d+)\s*(seconds?|minutes?|hours?|days?|weeks?|milliseconds?)$/)
        raise ConfigValidationError.new("Invalid time span format: '#{time_str}'. Expected format: '5 seconds', '2 minutes', '1 hour', etc.")
      end
    end

    private def self.validate_timezone(timezone : String)
      Time::Location.load(timezone)
    rescue
      raise ConfigValidationError.new("Invalid timezone: '#{timezone}'. Use IANA timezone identifiers like 'America/New_York', 'UTC', etc.")
    end

    private def self.validate_throttle(throttle : YAML::Any, queue_name : String)
      unless throttle["limit"]?
        raise ConfigValidationError.new("Queue '#{queue_name}' throttle missing 'limit' field")
      end

      unless throttle["period"]?
        raise ConfigValidationError.new("Queue '#{queue_name}' throttle missing 'period' field")
      end

      limit = throttle["limit"].as_i
      raise ConfigValidationError.new("Queue '#{queue_name}' throttle limit must be > 0") if limit <= 0

      period = throttle["period"].as_s
      validate_time_span(period)
    end

    private def self.validate_cron_pattern(pattern : String)
      # Basic cron pattern validation
      parts = pattern.split
      unless parts.size == 5
        raise ConfigValidationError.new("Invalid cron pattern: '#{pattern}' (must have 5 fields: minute hour day month weekday)")
      end

      # Validate each field
      parts.each_with_index do |part, index|
        field_name = ["minute", "hour", "day", "month", "weekday"][index]

        # Allow wildcards, ranges, lists, and steps
        unless part.match(/^(\*|([0-5]?\d)(-([0-5]?\d))?(\/([0-5]?\d))?|(\d{1,2})(,(\d{1,2}))*)$/) ||
               part.match(/^(\*|[0-2]?\d(-[0-2]?\d)?(\/[0-2]?\d)?|[0-2]?\d(,[0-2]?\d)*)$/) ||
               part.match(/^(\*|[1-2]?\d(-[1-2]?\d)?(\/[1-2]?\d)?|[1-2]?\d(,[1-2]?\d)*)$/) ||
               part.match(/^(\*|[0-1]?\d(-[0-1]?\d)?(\/[0-1]?\d)?|[0-1]?\d(,[0-1]?\d)*)$/) ||
               part.match(/^(\*|[0-6](-[0-6])?(\/[0-6])?|[0-6](,[0-6])*)$/)
          raise ConfigValidationError.new("Invalid cron pattern: '#{pattern}' (invalid #{field_name} field: '#{part}')")
        end
      end
    end
  end
end
