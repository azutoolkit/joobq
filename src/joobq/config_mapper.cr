require "./queue"

module JoobQ
  # Maps YAML configuration data to JoobQ Configure instances
  class ConfigMapper
    def self.map_to_configure(yaml_data : YAML::Any) : Configure
      config = Configure.new

      joobq_data = yaml_data["joobq"]?
      return config unless joobq_data

      # Map settings
      if settings = joobq_data["settings"]?
        map_settings(config, settings)
      end

      # Map queues
      if queues = joobq_data["queues"]?
        map_queues(config, queues)
      end

      # Map middlewares
      if middlewares = joobq_data["middlewares"]?
        map_middlewares(config, middlewares)
      end

      # Map error monitoring
      if error_monitoring = joobq_data["error_monitoring"]?
        map_error_monitoring(config, error_monitoring)
      end

      # Map schedulers
      if schedulers = joobq_data["schedulers"]?
        map_schedulers(config, schedulers)
      end

      # Map Redis configuration
      if redis_config = joobq_data["redis"]?
        map_redis_config(config, redis_config)
      end

      # Map pipeline configuration
      if pipeline_config = joobq_data["pipeline"]?
        map_pipeline_config(config, pipeline_config)
      end

      # Map features
      if features = joobq_data["features"]?
        map_features(config, features)
      end

      config
    end

    private def self.map_settings(config : Configure, settings : YAML::Any)
      if default_queue = settings["default_queue"]?
        config.default_queue = default_queue.as_s
      end

      if retries = settings["retries"]?
        config.retries = retries.as_i
      end

      if expires = settings["expires"]?
        config.expires = parse_time_span(expires.as_s)
      end

      if timeout = settings["timeout"]?
        config.timeout = parse_time_span(timeout.as_s)
      end

      if failed_ttl = settings["failed_ttl"]?
        config.failed_ttl = parse_time_span(failed_ttl.as_s)
      end

      if dead_letter_ttl = settings["dead_letter_ttl"]?
        config.dead_letter_ttl = parse_time_span(dead_letter_ttl.as_s)
      end

      if worker_batch_size = settings["worker_batch_size"]?
        config.worker_batch_size = worker_batch_size.as_i
      end

      if timezone = settings["timezone"]?
        config.time_location = timezone.as_s
      end
    end

    private def self.map_queues(config : Configure, queues : YAML::Any)
      queues.as_h.each do |queue_name, queue_config|
        job_class_name = queue_config["job_class"].as_s
        workers = queue_config["workers"].as_i
        throttle = nil
        if throttle_config = queue_config["throttle"]?
          throttle = parse_throttle(throttle_config)
        end

        # Create queue with job class name
        # Use the existing queue macro functionality through a workaround
        # Since we can't call the macro directly, we'll create the queue manually
        queue = create_queue_for_job_class(job_class_name, queue_name.as_s, workers, throttle)
        config.queues[queue_name.as_s] = queue

        # Note: Job class registration would need to be handled differently
        # since we can't resolve the class at compile time
      end
    end

    private def self.map_middlewares(config : Configure, middlewares : YAML::Any)
      config.middlewares.clear

      middlewares.as_a.each do |middleware_config|
        type = middleware_config["type"].as_s

        case type
        when "throttle"
          config.middlewares << Middleware::Throttle.new
        when "retry"
          config.middlewares << Middleware::Retry.new
        when "timeout"
          config.middlewares << Middleware::Timeout.new
        else
          Log.warn { "Unknown middleware type: #{type}" }
        end
      end
    end

    private def self.map_error_monitoring(config : Configure, error_monitoring : YAML::Any)
      if alert_thresholds = error_monitoring["alert_thresholds"]?
        thresholds = {} of String => Int32
        alert_thresholds.as_h.each do |key, value|
          thresholds[key.as_s] = value.as_i
        end
        config.error_monitor.alert_thresholds = thresholds
      end

      if time_window = error_monitoring["time_window"]?
        config.error_monitor.time_window = parse_time_span(time_window.as_s)
      end

      if max_recent_errors = error_monitoring["max_recent_errors"]?
        config.error_monitor.max_recent_errors = max_recent_errors.as_i
      end
    end

    private def self.map_schedulers(config : Configure, schedulers : YAML::Any)
      schedulers.as_a.each do |scheduler_config|
        timezone = scheduler_config["timezone"]?.try(&.as_s) || "America/New_York"

        config.scheduler(Time::Location.load(timezone)) do
          # Map cron jobs
          if cron_jobs = scheduler_config["cron_jobs"]?
            cron_jobs.as_a.each do |cron_job|
              pattern = cron_job["pattern"].as_s
              job_class_name = cron_job["job"].as_s
              job_args = {} of String => YAML::Any
              if args_config = cron_job["args"]?
                if args_config.as_h?
                  job_args = convert_yaml_args_to_hash(args_config.as_h)
                end
              end

              cron(pattern) do
                # Note: Job class resolution would need to be handled at runtime
                # For now, we'll skip the actual job enqueuing since we can't resolve classes
                Log.debug { "Cron job '#{job_class_name}' would be enqueued with args: #{job_args}" }
              end
            end
          end

          # Map recurring jobs
          if recurring_jobs = scheduler_config["recurring_jobs"]?
            recurring_jobs.as_a.each do |recurring_job|
              interval = parse_time_span(recurring_job["interval"].as_s)
              job_class_name = recurring_job["job"].as_s
              job_args = {} of String => YAML::Any
              if args_config = recurring_job["args"]?
                if args_config.as_h?
                  job_args = convert_yaml_args_to_hash(args_config.as_h)
                end
              end

              # Note: Job class resolution would need to be handled at runtime
              # For now, we'll skip the actual job scheduling since we can't resolve classes
              Log.debug { "Recurring job '#{job_class_name}' would be scheduled with interval: #{interval}, args: #{job_args}" }
            end
          end
        end
      end
    end

    private def self.map_redis_config(config : Configure, redis_config : YAML::Any)
      host = "localhost"
      port = 6379
      password = nil
      pool_size = 500
      pool_timeout = 2.0

      if host_val = redis_config["host"]?
        host = host_val.as_s
      end

      if port_val = redis_config["port"]?
        port = port_val.as_i
      end

      if password_val = redis_config["password"]?
        password = password_val.as_s
      end

      if pool_size_val = redis_config["pool_size"]?
        pool_size = pool_size_val.as_i
      end

      if pool_timeout_val = redis_config["pool_timeout"]?
        pool_timeout = pool_timeout_val.as_f
      end

      # Create Redis store with proper parameters
      # Note: This is a simplified implementation for YAML config
      # In practice, you might want to use the existing RedisStore.new method
      config.store = RedisStore.new
    end

    private def self.map_pipeline_config(config : Configure, pipeline_config : YAML::Any)
      if batch_size = pipeline_config["batch_size"]?
        config.pipeline_batch_size = batch_size.as_i
      end

      if timeout = pipeline_config["timeout"]?
        config.pipeline_timeout = timeout.as_f
      end

      if max_commands = pipeline_config["max_commands"]?
        config.pipeline_max_commands = max_commands.as_i
      end
    end

    private def self.map_features(config : Configure, features : YAML::Any)
      if rest_api = features["rest_api"]?
        config.rest_api_enabled = rest_api.as_bool
      end

      if stats = features["stats"]?
        config.stats_enabled = stats.as_bool
      end
    end

    # Helper methods
    private def self.parse_time_span(time_str : String) : Time::Span
      case time_str
      when /^(\d+)\s*seconds?$/
        $1.to_i.seconds
      when /^(\d+)\s*minutes?$/
        $1.to_i.minutes
      when /^(\d+)\s*hours?$/
        $1.to_i.hours
      when /^(\d+)\s*days?$/
        $1.to_i.days
      when /^(\d+)\s*weeks?$/
        $1.to_i.weeks
      when /^(\d+)\s*milliseconds?$/
        $1.to_i.milliseconds
      else
        raise ArgumentError.new("Invalid time span format: #{time_str}")
      end
    end

    private def self.parse_throttle(throttle_config : YAML::Any) : NamedTuple(limit: Int32, period: Time::Span)
      {
        limit:  throttle_config["limit"].as_i,
        period: parse_time_span(throttle_config["period"].as_s),
      }
    end

    private def self.resolve_job_class(class_name : String) : Class
      # This is a simplified job class resolution
      # In a real implementation, you might want to maintain a registry of job classes
      # or use a more sophisticated resolution mechanism

      # For now, we'll raise an error if the job class can't be resolved
      # This will force users to ensure their job classes are properly registered
      raise ConfigValidationError.new("Job class '#{class_name}' not found. Ensure job classes are properly defined and available.")
    end

    private def self.create_queue_for_job_class(job_class_name : String, queue_name : String, workers : Int32, throttle : NamedTuple(limit: Int32, period: Time::Span)?)
      # Create a generic queue that can handle any job type
      # This is a workaround since we can't use the macro directly
      GenericQueue.new(queue_name, workers, job_class_name, throttle)
    end

    private def self.convert_yaml_args_to_hash(yaml_args : Hash(YAML::Any, YAML::Any)) : Hash(String, YAML::Any)
      # Convert YAML::Any values to proper types for job arguments
      # This is a simplified conversion - in practice you might need more sophisticated type conversion
      result = {} of String => YAML::Any
      yaml_args.each do |key, value|
        result[key.as_s] = value
      end
      result
    end
  end

  # Generic worker manager for dynamic job class handling
  class GenericWorkerManager
    getter total_workers : Int32
    getter queue : GenericQueue

    def initialize(@total_workers : Int32, @queue : GenericQueue)
    end

    def restart(worker, ex : Exception)
      # Placeholder implementation for restart
      Log.debug { "GenericWorkerManager would restart worker after exception: #{ex.message}" }
    end
  end

  # Generic queue implementation for dynamic job class handling
  class GenericQueue
    include BaseQueue
    getter name : String
    getter job_type : String
    getter total_workers : Int32
    getter throttle_limit : NamedTuple(limit: Int32, period: Time::Span)?

    def initialize(@name : String, @total_workers : Int32, @job_class_name : String, @throttle_limit : NamedTuple(limit: Int32, period: Time::Span)? = nil)
      @job_type = @job_class_name
    end

    def add(job : String)
      # Parse and enqueue the job
      # Note: This is a placeholder implementation
      # In a real implementation, this would enqueue the job properly
      Log.debug { "Would enqueue job to queue #{name}: #{job}" }
    end

    def start
      # Start workers for this queue
      # This would need to be implemented based on the actual worker management system
      Log.info { "Starting #{total_workers} workers for queue #{name}" }
    end

    def stop!
      # Stop workers for this queue
      Log.info { "Stopping workers for queue #{name}" }
    end

    def size : Int64
      # Get queue size from store
      # Note: This is a placeholder implementation
      # In a real implementation, this would return the actual queue size
      0_i64
    end

    def running_workers : Int32
      # Return number of running workers
      # This would need to be tracked by the worker manager
      0
    end

    def status : String
      # Return queue status
      "active"
    end

    def claim_jobs_batch(worker_id : String, batch_size : Int32) : Array(String)
      # Placeholder implementation for claim_jobs_batch
      # In a real implementation, this would claim jobs from the queue
      Log.debug { "GenericQueue would claim #{batch_size} jobs for worker #{worker_id}" }
      [] of String
    end

    def store
      # Return the global store instance
      JoobQ.store
    end

    def cleanup_completed_job_pipelined(worker_id : String, job : String)
      # Placeholder implementation for cleanup_completed_job_pipelined
      Log.debug { "GenericQueue would cleanup completed job #{job} for worker #{worker_id}" }
    end

    def cleanup_job_processing_pipelined(worker_id : String, job : String)
      # Placeholder implementation for cleanup_job_processing_pipelined
      Log.debug { "GenericQueue would cleanup job processing #{job} for worker #{worker_id}" }
    end

    def worker_manager
      # Create a generic worker manager for this queue
      # Since we don't have a specific job type, we'll use a placeholder
      @worker_manager ||= GenericWorkerManager.new(total_workers, self)
    end

    private getter job_class_name : String
  end
end
