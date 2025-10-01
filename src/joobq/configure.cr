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
    Log.setup_from_env(default_level: :trace)
    # Properties and Getters
    getter queues = {} of String => BaseQueue
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
    property worker_batch_size : Int32 = 5
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
    )
      error_monitor.alert_thresholds = alert_thresholds if alert_thresholds
      error_monitor.time_window = time_window if time_window
      error_monitor.max_recent_errors = max_recent_errors if max_recent_errors
    end
  end
end
