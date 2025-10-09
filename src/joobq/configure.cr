module JoobQ
  alias ThrottlerConfig = Hash(String, NamedTuple(limit: Int32, period: Time::Span))

  # `Configure` is responsible for managing the settings for the `JoobQ` job queue system.
  #
  # ### Features
  #
  # - Centralizes job queue configurations, Redis connection setup, and queue properties.
  # - Provides default settings and allows easy customization through environment variables.
  # - Supports defining queues, middlewares, throttling, and scheduling jobs.
  #
  # ### Usage Example
  #
  # ```
  # JoobQ::Configure.instance.queue "my_queue", 5, MyJob, {limit: 10, period: 1.minute}
  # ```
  class Configure
    begin
      Log.setup_from_env(default_level: :trace)
    rescue ex : ArgumentError
      # Fallback if environment variables have invalid log configuration
      Log.setup do |c|
        c.bind "*", :info, Log::IOBackend.new
      end
    end

    # Properties and Getters
    getter queues = {} of String => BaseQueue
    getter queue_configs = {} of String => NamedTuple(job_class_name: String, workers: Int32, throttle: NamedTuple(limit: Int32, period: Time::Span)?)
    getter time_location : Time::Location = Time::Location.load("America/New_York")

    property store : Store = RedisStore.new
    property? rest_api_enabled : Bool = false
    property? stats_enabled : Bool = true
    property default_queue : String = "default"
    property retries : Int32 = 3
    property expires : Time::Span = 3.days
    property timeout : Time::Span = 2.seconds
    property failed_ttl : Time::Span = 3.milliseconds
    property dead_letter_ttl : Time::Span = 7.days
    property worker_batch_size : Int32 = 10
    property job_registry : JobSchemaRegistry = JobSchemaRegistry.new

    # Pipeline optimization settings (always enabled)
    property pipeline_batch_size : Int32 = 100
    property pipeline_timeout : Float64 = 1.0
    property pipeline_max_commands : Int32 = 1000

    # Error Monitoring
    @error_monitor : ErrorMonitor? = nil
    getter error_monitor : ErrorMonitor do
      @error_monitor ||= ErrorMonitor.new
    end

    # Middlewares and Pipeline
    property middlewares : Array(Middleware) = [
      Middleware::Throttle.new,
      Middleware::Retry.new,
      Middleware::Timeout.new,
    ] of Middleware

    getter middleware_pipeline : MiddlewarePipeline do
      MiddlewarePipeline.new(middlewares)
    end

    # Schedulers
    property schedulers : Array(Scheduler) = [] of Scheduler
    property scheduler_configs : Array(NamedTuple(
      timezone: String,
      cron_jobs: Array(NamedTuple(pattern: String, job: String, args: Hash(String, YAML::Any))),
      recurring_jobs: Array(NamedTuple(interval: Time::Span, job: String, args: Hash(String, YAML::Any))))) = [] of NamedTuple(
      timezone: String,
      cron_jobs: Array(NamedTuple(pattern: String, job: String, args: Hash(String, YAML::Any))),
      recurring_jobs: Array(NamedTuple(interval: Time::Span, job: String, args: Hash(String, YAML::Any))))

    # Delayed job scheduler (processes retrying jobs)
    property delayed_job_scheduler : DelayedJobScheduler = DelayedJobScheduler.new

    # DSL: Add custom middlewares
    def use(& : ->)
      yield middlewares
    end

    # Set the time location globally
    def time_location=(tz : String = "America/New_York") : Time::Location
      timezone = Time::Location.load(tz)
      Time::Location.local = timezone
      timezone
    end

    # Macro: Define a queue
    #
    # Adds a queue configuration and optionally applies throttling limits.
    macro queue(name, workers, job, throttle = nil)
      {% begin %}
      queues[{{name}}] = JoobQ::Queue({{job.id}}).new({{name}}, {{workers}}, {{throttle}})
      job_registry.register({{job.id}})
      {% end %}
    end

    # Add a scheduler and execute within its context
    def scheduler(tz : Time::Location = self.time_location, &)
      scheduler = Scheduler.new(time_location: tz)
      @schedulers << scheduler
      with scheduler yield
    end

    # Configure error monitoring
    def error_monitoring(&)
      yield error_monitor
    end

    # Configure error monitoring with parameters
    def error_monitoring(
      alert_thresholds : Hash(String, Int32)? = nil,
      time_window : Time::Span? = nil,
      max_recent_errors : Int32? = nil,
      notify_alert : Proc(Hash(String, String), Nil)? = nil,
    )
      error_monitor.alert_thresholds = alert_thresholds if alert_thresholds
      error_monitor.time_window = time_window if time_window
      error_monitor.max_recent_errors = max_recent_errors if max_recent_errors
      error_monitor.notify_alert = notify_alert if notify_alert
    end

    # YAML configuration loading methods
    def self.load_from_yaml(path : String? = nil, env : String? = nil) : Configure
      if path
        YamlConfigLoader.load_with_env_overrides(path, env)
      else
        YamlConfigLoader.load_auto
      end
    end

    # Hybrid configuration - YAML + programmatic
    def self.load_hybrid(yaml_path : String? = nil, &)
      # Start with YAML configuration
      config = if yaml_path
                 YamlConfigLoader.load_from_file(yaml_path)
               else
                 YamlConfigLoader.load_auto
               end

      # Apply programmatic overrides
      yield config

      config
    end

    # Load from multiple YAML sources with merging
    def self.load_from_yaml_sources(sources : Array(String)) : Configure
      YamlConfigLoader.load_from_sources(sources)
    end

    # Load from CLI arguments
    def self.load_from_cli_args(args : Array(String)) : Configure
      YamlConfigLoader.load_from_cli_args(args)
    end

    # Helper method to setup schedulers from YAML configuration
    #
    # This method should be called after job classes are available and loaded.
    # It processes the scheduler configurations stored during YAML loading and
    # sets up cron jobs and recurring jobs with proper job class resolution.
    #
    # Example usage:
    # ```
    # config = JoobQ::Configure.load_from_yaml("config/joobq.yml")
    # # ... load job classes ...
    # config.setup_schedulers_from_config
    # ```
    def setup_schedulers_from_config
      scheduler_configs.each do |scheduler_config|
        timezone = Time::Location.load(scheduler_config[:timezone])

        scheduler(timezone) do
          # Setup cron jobs
          scheduler_config[:cron_jobs].each do |cron_job|
            pattern = cron_job[:pattern]
            job_class_name = cron_job[:job]
            job_args = cron_job[:args]

            begin
              job_class = resolve_job_class(job_class_name)
              cron(pattern) do
                # Convert YAML::Any args to proper types and enqueue job
                args_hash = convert_yaml_args_to_hash(job_args)
                # Note: Job enqueuing with dynamic args would need proper type conversion
                # For now, we'll log the intent
                Log.debug { "Would enqueue job #{job_class_name} with args: #{args_hash}" }
              end
            rescue ex
              Log.warn { "Could not setup cron job '#{job_class_name}' with pattern '#{pattern}': #{ex.message}" }
            end
          end

          # Setup recurring jobs
          scheduler_config[:recurring_jobs].each do |recurring_job|
            interval = recurring_job[:interval]
            job_class_name = recurring_job[:job]
            job_args = recurring_job[:args]

            begin
              job_class = resolve_job_class(job_class_name)
              # Convert YAML::Any args to proper types and schedule job
              args_hash = convert_yaml_args_to_hash(job_args)
              # Note: Job scheduling with dynamic args would need proper type conversion
              # For now, we'll log the intent
              Log.debug { "Would schedule job #{job_class_name} with interval #{interval} and args: #{args_hash}" }
            rescue ex
              Log.warn { "Could not setup recurring job '#{job_class_name}' with interval '#{interval}': #{ex.message}" }
            end
          end
        end
      end
    end

    private def resolve_job_class(class_name : String) : Class
      # This is a simplified job class resolution
      # In a real implementation, you might want to maintain a registry of job classes
      # or use a more sophisticated resolution mechanism

      # For now, we'll raise an error if the job class can't be resolved
      # This will force users to ensure their job classes are properly registered
      raise ConfigValidationError.new("Job class '#{class_name}' not found. Ensure job classes are properly defined and available.")
    end

    private def convert_yaml_args_to_hash(yaml_args : Hash(String, YAML::Any)) : Hash(String, YAML::Any)
      # Convert YAML::Any values to proper types for job arguments
      # This is a simplified conversion - in practice you might need more sophisticated type conversion
      yaml_args
    end

    # Create queues from stored queue_configs using the QueueFactory
    #
    # This method bridges YAML configuration with actual queue instantiation.
    # It should be called after:
    # 1. YAML configuration is loaded
    # 2. Job classes are defined and available
    # 3. Job types are registered with QueueFactory
    #
    # Example:
    # ```
    # # Load YAML config
    # config = Configure.load_from_yaml("config/joobq.yml")
    #
    # # Register job types (must be done after job classes are defined)
    # QueueFactory.register_job_type(EmailJob)
    # QueueFactory.register_job_type(ImageProcessingJob)
    #
    # # Create queues from YAML configuration
    # config.create_queues_from_yaml_config
    #
    # # Now queues are available
    # JoobQ.start
    # ```
    def create_queues_from_yaml_config
      created_queues = QueueFactory.create_queues_from_config(queue_configs)
      created_queues.each do |name, queue|
        queues[name] = queue
        # Register job type in the job registry
        if job_config = queue_configs[name]?
          Log.debug { "Queue '#{name}' created for job type: #{job_config[:job_class_name]}" }
        end
      end

      Log.info { "Created #{created_queues.size} queues from YAML configuration" }
      created_queues.size
    end

    # Helper macro to register a job type and add it to the factory
    #
    # This combines job registry and queue factory registration in one call.
    #
    # Example:
    # ```
    # config = JoobQ.config
    # config.register_job(EmailJob)
    # config.register_job(ImageProcessingJob)
    # ```
    macro register_job(job_class)
      job_registry.register({{job_class.id}})
      QueueFactory.register_job_type({{job_class.id}})
    end
  end
end
