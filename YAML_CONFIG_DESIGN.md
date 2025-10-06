# YAML Configuration Loader - Technical Design Document

## Overview

This document outlines the design and implementation of a YAML configuration loader for the JoobQ job queue system. The loader will provide a declarative way to configure queues, middlewares, schedulers, error monitoring, and other system components through YAML files instead of imperative Crystal code.

## Current State Analysis

### Existing Configuration System

The current `Configure` class provides:

- **Queue Configuration**: Via macro `queue(name, workers, job, throttle)`
- **Middleware Pipeline**: Default middlewares (Throttle, Retry, Timeout)
- **Error Monitoring**: Configurable thresholds and time windows
- **Scheduler Support**: Timezone-aware schedulers
- **Redis Store**: Environment-based configuration
- **Pipeline Optimization**: Batch processing settings

### Configuration Properties

```crystal
# Core Settings
- default_queue: String = "default"
- retries: Int32 = 3
- expires: Time::Span = 3.days
- timeout: Time::Span = 2.seconds
- failed_ttl: Time::Span = 3.milliseconds
- dead_letter_ttl: Time::Span = 7.days
- worker_batch_size: Int32 = 10

# Pipeline Settings
- pipeline_batch_size: Int32 = 100
- pipeline_timeout: Float64 = 1.0
- pipeline_max_commands: Int32 = 1000

# Features
- rest_api_enabled: Bool = false
- stats_enabled: Bool = true
- time_location: Time::Location = "America/New_York"
```

## Design Goals

1. **Backward Compatibility**: Existing Crystal configuration should continue to work
2. **Type Safety**: Maintain Crystal's compile-time type checking
3. **Validation**: Comprehensive YAML schema validation
4. **Flexibility**: Support both simple and complex configurations
5. **Performance**: Minimal runtime overhead
6. **Extensibility**: Easy to add new configuration options

## Architecture

### Core Components

```
YamlConfigLoader
├── YamlConfigParser      # YAML parsing and validation
├── ConfigSchema         # YAML schema definition
├── ConfigValidator      # Runtime validation
├── ConfigMapper         # YAML to Configure mapping
└── ConfigLoader         # Main entry point
```

### Dependencies

Add to `shard.yml`:

```yaml
dependencies:
  yaml:
    github: crystal-lang/yaml
```

## YAML Schema Design

### Top-Level Structure

```yaml
# joobq.yml
joobq:
  # Core configuration
  settings:
    default_queue: "default"
    retries: 3
    expires: "3 days"
    timeout: "2 seconds"
    timezone: "America/New_York"

  # Queue definitions
  queues:
    email_queue:
      job_class: "EmailJob"
      workers: 5
      throttle:
        limit: 10
        period: "1 minute"

    image_queue:
      job_class: "ImageProcessingJob"
      workers: 3
      throttle:
        limit: 5
        period: "30 seconds"

  # Middleware configuration
  middlewares:
    - type: "throttle"
    - type: "retry"
    - type: "timeout"

  # Error monitoring
  error_monitoring:
    alert_thresholds:
      error: 10
      warn: 50
      info: 100
    time_window: "5 minutes"
    max_recent_errors: 100

  # Schedulers
  schedulers:
    - timezone: "America/New_York"
      cron_jobs:
        - pattern: "0 */6 * * *"
          job: "CleanupJob"
          args: {}
        - pattern: "0 0 * * *"
          job: "DailyReportJob"
          args: { report_type: "daily" }
      recurring_jobs:
        - interval: "5 minutes"
          job: "HealthCheckJob"
          args: {}

  # Redis configuration
  redis:
    host: "localhost"
    port: 6379
    password: null
    pool_size: 500
    pool_timeout: 2.0

  # Pipeline optimization
  pipeline:
    batch_size: 100
    timeout: 1.0
    max_commands: 1000

  # API features
  features:
    rest_api: false
    stats: true
```

## Implementation Details

### 1. YamlConfigLoader Class

```crystal
module JoobQ
  class YamlConfigLoader
    include JSON::Serializable

    # Configuration file search paths (in order of precedence)
    DEFAULT_SEARCH_PATHS = [
      "./joobq.yml",
      "./config/joobq.yml",
      "./config/joobq.yaml",
      "./joobq.yaml",
      ENV["JOOBQ_CONFIG_PATH"]?,
      ENV["JOOBQ_CONFIG_FILE"]?,
      "~/.joobq/joobq.yml",
      "/etc/joobq/joobq.yml"
    ].compact

    # Environment-specific file patterns
    ENV_FILE_PATTERNS = [
      "./config/joobq.#{ENV["JOOBQ_ENV"]? || "development"}.yml",
      "./config/joobq.#{ENV["RACK_ENV"]? || "development"}.yml",
      "./config/joobq.#{ENV["CRYSTAL_ENV"]? || "development"}.yml"
    ]

    # Main entry points
    def self.load_from_file(path : String) : Configure
      expanded_path = File.expand_path(path)
      unless File.exists?(expanded_path)
        raise ConfigFileNotFoundError.new("Configuration file not found: #{expanded_path}")
      end

      content = File.read(expanded_path)
      load_from_string(content, expanded_path)
    rescue ex : File::NotFoundError
      raise ConfigFileNotFoundError.new("Configuration file not found: #{expanded_path}")
    rescue ex : Exception
      raise ConfigLoadError.new("Failed to load configuration from #{expanded_path}: #{ex.message}")
    end

    def self.load_from_string(yaml_content : String, source_path : String? = nil) : Configure
      config_data = YAML.parse(yaml_content)
      validate_schema(config_data, source_path)
      map_to_configure(config_data, source_path)
    rescue ex : YAML::ParseException
      raise ConfigParseError.new("Invalid YAML syntax#{source_path ? " in #{source_path}" : ""}: #{ex.message}")
    rescue ex : Exception
      raise ConfigLoadError.new("Failed to parse configuration#{source_path ? " from #{source_path}" : ""}: #{ex.message}")
    end

    # Auto-discovery methods
    def self.load_auto : Configure
      config_path = find_config_file
      if config_path
        Log.info { "Loading JoobQ configuration from: #{config_path}" }
        load_from_file(config_path)
      else
        Log.warn { "No JoobQ configuration file found, using default configuration" }
        Configure.new
      end
    end

    def self.find_config_file : String?
      # First check environment-specific files
      ENV_FILE_PATTERNS.each do |pattern|
        expanded_path = File.expand_path(pattern)
        return expanded_path if File.exists?(expanded_path)
      end

      # Then check default search paths
      DEFAULT_SEARCH_PATHS.each do |path|
        next unless path
        expanded_path = File.expand_path(path)
        return expanded_path if File.exists?(expanded_path)
      end

      nil
    end

    # Load with environment override support
    def self.load_with_env_overrides(base_path : String? = nil, env : String? = nil) : Configure
      # Determine environment
      environment = env || ENV["JOOBQ_ENV"]? || ENV["RACK_ENV"]? || ENV["CRYSTAL_ENV"]? || "development"

      # Try to load environment-specific config first
      env_config_path = nil
      if base_path
        env_config_path = "#{base_path}.#{environment}.yml"
      else
        env_config_path = "./config/joobq.#{environment}.yml"
      end

      # Load base configuration
      config = if File.exists?(File.expand_path(env_config_path))
        Log.info { "Loading environment-specific config: #{env_config_path}" }
        load_from_file(env_config_path)
      elsif base_path
        load_from_file(base_path)
      else
        load_auto
      end

      # Apply environment variable overrides
      apply_env_overrides(config, environment)

      config
    end

    # Load from multiple sources with merging
    def self.load_from_sources(sources : Array(String)) : Configure
      base_config = Configure.new

      sources.each do |source|
        if File.exists?(source)
          Log.debug { "Loading configuration from: #{source}" }
          source_config = load_from_file(source)
          base_config = merge_configurations(base_config, source_config)
        else
          Log.warn { "Configuration source not found: #{source}" }
        end
      end

      base_config
    end

    # CLI and programmatic configuration methods
    def self.load_from_cli_args(args : Array(String)) : Configure
      config_path = nil
      environment = nil

      # Parse command line arguments
      i = 0
      while i < args.size
        case args[i]
        when "--config", "-c"
          config_path = args[i + 1] if i + 1 < args.size
          i += 2
        when "--env", "-e"
          environment = args[i + 1] if i + 1 < args.size
          i += 2
        when "--help", "-h"
          print_usage
          exit 0
        else
          i += 1
        end
      end

      if config_path
        load_with_env_overrides(config_path, environment)
      else
        load_with_env_overrides(environment: environment)
      end
    end

    private def self.apply_env_overrides(config : Configure, environment : String) : Nil
      # Apply environment variable overrides
      # Format: JOOBQ_SETTING_NAME=value

      ENV.each do |key, value|
        next unless key.starts_with?("JOOBQ_")

        setting_name = key[6..-1].downcase # Remove "JOOBQ_" prefix

        case setting_name
        when "default_queue"
          config.default_queue = value
        when "retries"
          config.retries = value.to_i
        when "expires"
          config.expires = parse_time_span(value)
        when "timeout"
          config.timeout = parse_time_span(value)
        when "timezone"
          config.time_location = Time::Location.load(value)
        when "worker_batch_size"
          config.worker_batch_size = value.to_i
        when "pipeline_batch_size"
          config.pipeline_batch_size = value.to_i
        when "pipeline_timeout"
          config.pipeline_timeout = value.to_f
        when "pipeline_max_commands"
          config.pipeline_max_commands = value.to_i
        when "rest_api_enabled"
          config.rest_api_enabled = ["true", "1", "yes", "on"].includes?(value.downcase)
        when "stats_enabled"
          config.stats_enabled = ["true", "1", "yes", "on"].includes?(value.downcase)
        when "redis_host"
          # Redis config override would need special handling
          Log.debug { "Redis host override via environment: #{value}" }
        when "redis_port"
          Log.debug { "Redis port override via environment: #{value}" }
        end
      end

      Log.info { "Applied environment overrides for environment: #{environment}" }
    end

    private def self.merge_configurations(base : Configure, override : Configure) : Configure
      # Create a new config with merged values
      merged = Configure.new

      # Apply base configuration
      merged.default_queue = base.default_queue
      merged.retries = base.retries
      merged.expires = base.expires
      merged.timeout = base.timeout
      merged.failed_ttl = base.failed_ttl
      merged.dead_letter_ttl = base.dead_letter_ttl
      merged.worker_batch_size = base.worker_batch_size
      merged.pipeline_batch_size = base.pipeline_batch_size
      merged.pipeline_timeout = base.pipeline_timeout
      merged.pipeline_max_commands = base.pipeline_max_commands
      merged.rest_api_enabled = base.rest_api_enabled
      merged.stats_enabled = base.stats_enabled
      merged.time_location = base.time_location

      # Merge queues (override takes precedence)
      base.queues.each { |name, queue| merged.queues[name] = queue }
      override.queues.each { |name, queue| merged.queues[name] = queue }

      # Merge middlewares (override replaces)
      if override.middlewares.any?
        merged.middlewares = override.middlewares
      else
        merged.middlewares = base.middlewares
      end

      # Merge error monitoring config
      if override.error_monitor.alert_thresholds.any?
        merged.error_monitor.alert_thresholds = override.error_monitor.alert_thresholds
      else
        merged.error_monitor.alert_thresholds = base.error_monitor.alert_thresholds
      end

      if override.error_monitor.time_window != Time::Span.zero
        merged.error_monitor.time_window = override.error_monitor.time_window
      else
        merged.error_monitor.time_window = base.error_monitor.time_window
      end

      if override.error_monitor.max_recent_errors != 0
        merged.error_monitor.max_recent_errors = override.error_monitor.max_recent_errors
      else
        merged.error_monitor.max_recent_errors = base.error_monitor.max_recent_errors
      end

      # Override store if specified
      merged.store = override.store unless override.store.is_a?(RedisStore) &&
        override.store.redis.host == "localhost" && override.store.redis.port == 6379

      # Merge schedulers
      merged.schedulers = base.schedulers + override.schedulers

      merged
    end

    private def self.validate_schema(data : YAML::Any, source_path : String? = nil)
      # Schema validation logic with source path context
      ConfigValidator.validate(data)
    rescue ex : ConfigValidationError
      raise ConfigValidationError.new("#{ex.message}#{source_path ? " in #{source_path}" : ""}")
    end

    private def self.map_to_configure(data : YAML::Any, source_path : String? = nil) : Configure
      # Mapping logic with source path context for better error reporting
      ConfigMapper.map_to_configure(data)
    end

    private def self.print_usage : Nil
      puts <<-USAGE
        JoobQ Configuration Loader Usage:

        Options:
          -c, --config PATH    Specify configuration file path
          -e, --env ENV        Specify environment (development, production, test)
          -h, --help          Show this help message

        Configuration File Discovery:
          1. Environment-specific files: ./config/joobq.{env}.yml
          2. Default locations:
             - ./joobq.yml
             - ./config/joobq.yml
             - ./config/joobq.yaml
             - ./joobq.yaml
          3. Environment variables: JOOBQ_CONFIG_PATH, JOOBQ_CONFIG_FILE
          4. User/system locations: ~/.joobq/joobq.yml, /etc/joobq/joobq.yml

        Environment Variable Overrides:
          JOOBQ_DEFAULT_QUEUE, JOOBQ_RETRIES, JOOBQ_TIMEOUT, etc.

        Examples:
          joobq --config ./my-config.yml
          joobq --env production
          joobq -c ./config/joobq.yml -e production
      USAGE
    end

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
  end

  # Custom exception classes
  class ConfigFileNotFoundError < Exception
  end

  class ConfigParseError < Exception
  end

  class ConfigLoadError < Exception
  end
end
```

### 2. Configuration Schema

```crystal
module JoobQ
  struct YamlConfigSchema
    include JSON::Serializable

    property joobq : MainConfig

    struct MainConfig
      include JSON::Serializable

      property settings : SettingsConfig?
      property queues : Hash(String, QueueConfig)?
      property middlewares : Array(MiddlewareConfig)?
      property error_monitoring : ErrorMonitoringConfig?
      property schedulers : Array(SchedulerConfig)?
      property redis : RedisConfig?
      property pipeline : PipelineConfig?
      property features : FeaturesConfig?
    end

    struct SettingsConfig
      include JSON::Serializable

      property default_queue : String?
      property retries : Int32?
      property expires : String?
      property timeout : String?
      property timezone : String?
      property failed_ttl : String?
      property dead_letter_ttl : String?
      property worker_batch_size : Int32?
    end

    struct QueueConfig
      include JSON::Serializable

      property job_class : String
      property workers : Int32
      property throttle : ThrottleConfig?
    end

    struct ThrottleConfig
      include JSON::Serializable

      property limit : Int32
      property period : String
    end

    struct MiddlewareConfig
      include JSON::Serializable

      property type : String
      property config : Hash(String, YAML::Any)?
    end

    struct ErrorMonitoringConfig
      include JSON::Serializable

      property alert_thresholds : Hash(String, Int32)?
      property time_window : String?
      property max_recent_errors : Int32?
    end

    struct SchedulerConfig
      include JSON::Serializable

      property timezone : String?
      property cron_jobs : Array(CronJobConfig)?
      property recurring_jobs : Array(RecurringJobConfig)?
    end

    struct CronJobConfig
      include JSON::Serializable

      property pattern : String
      property job : String
      property args : Hash(String, YAML::Any)?
    end

    struct RecurringJobConfig
      include JSON::Serializable

      property interval : String
      property job : String
      property args : Hash(String, YAML::Any)?
    end

    struct RedisConfig
      include JSON::Serializable

      property host : String?
      property port : Int32?
      property password : String?
      property pool_size : Int32?
      property pool_timeout : Float64?
    end

    struct PipelineConfig
      include JSON::Serializable

      property batch_size : Int32?
      property timeout : Float64?
      property max_commands : Int32?
    end

    struct FeaturesConfig
      include JSON::Serializable

      property rest_api : Bool?
      property stats : Bool?
    end
  end
end
```

### 3. Configuration Mapper

```crystal
module JoobQ
  class ConfigMapper
    def self.map_to_configure(yaml_data : YAML::Any) : Configure
      config = Configure.new

      # Map settings
      if settings = yaml_data["joobq"]["settings"]?
        map_settings(config, settings)
      end

      # Map queues
      if queues = yaml_data["joobq"]["queues"]?
        map_queues(config, queues)
      end

      # Map middlewares
      if middlewares = yaml_data["joobq"]["middlewares"]?
        map_middlewares(config, middlewares)
      end

      # Map error monitoring
      if error_monitoring = yaml_data["joobq"]["error_monitoring"]?
        map_error_monitoring(config, error_monitoring)
      end

      # Map schedulers
      if schedulers = yaml_data["joobq"]["schedulers"]?
        map_schedulers(config, schedulers)
      end

      # Map Redis configuration
      if redis_config = yaml_data["joobq"]["redis"]?
        map_redis_config(config, redis_config)
      end

      # Map pipeline configuration
      if pipeline_config = yaml_data["joobq"]["pipeline"]?
        map_pipeline_config(config, pipeline_config)
      end

      # Map features
      if features = yaml_data["joobq"]["features"]?
        map_features(config, features)
      end

      config
    end

    private def self.map_settings(config : Configure, settings : YAML::Any)
      config.default_queue = settings["default_queue"]?.as_s if settings["default_queue"]?
      config.retries = settings["retries"]?.as_i if settings["retries"]?
      config.expires = parse_time_span(settings["expires"]?.as_s) if settings["expires"]?
      config.timeout = parse_time_span(settings["timeout"]?.as_s) if settings["timeout"]?
      config.time_location = settings["timezone"]?.as_s if settings["timezone"]?
      # ... other settings
    end

    private def self.map_queues(config : Configure, queues : YAML::Any)
      queues.as_h.each do |queue_name, queue_config|
        job_class = resolve_job_class(queue_config["job_class"].as_s)
        workers = queue_config["workers"].as_i
        throttle = parse_throttle(queue_config["throttle"]?) if queue_config["throttle"]?

        # Use the existing queue macro functionality
        config.queue(queue_name, workers, job_class, throttle)
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
              job_class = resolve_job_class(cron_job["job"].as_s)
              args = cron_job["args"]?.try(&.as_h) || {} of String => YAML::Any

              cron(pattern) do
                job_class.enqueue(**args)
              end
            end
          end

          # Map recurring jobs
          if recurring_jobs = scheduler_config["recurring_jobs"]?
            recurring_jobs.as_a.each do |recurring_job|
              interval = parse_time_span(recurring_job["interval"].as_s)
              job_class = resolve_job_class(recurring_job["job"].as_s)
              args = recurring_job["args"]?.try(&.as_h) || {} of String => YAML::Any

              every(interval, job_class, **args)
            end
          end
        end
      end
    end

    private def self.map_redis_config(config : Configure, redis_config : YAML::Any)
      host = redis_config["host"]?.try(&.as_s) || "localhost"
      port = redis_config["port"]?.try(&.as_i) || 6379
      password = redis_config["password"]?.try(&.as_s)
      pool_size = redis_config["pool_size"]?.try(&.as_i) || 500
      pool_timeout = redis_config["pool_timeout"]?.try(&.as_f) || 2.0

      config.store = RedisStore.new(host, port, password, pool_size, pool_timeout)
    end

    private def self.map_pipeline_config(config : Configure, pipeline_config : YAML::Any)
      config.pipeline_batch_size = pipeline_config["batch_size"]?.as_i if pipeline_config["batch_size"]?
      config.pipeline_timeout = pipeline_config["timeout"]?.as_f if pipeline_config["timeout"]?
      config.pipeline_max_commands = pipeline_config["max_commands"]?.as_i if pipeline_config["max_commands"]?
    end

    private def self.map_features(config : Configure, features : YAML::Any)
      config.rest_api_enabled = features["rest_api"]?.as_bool if features["rest_api"]?
      config.stats_enabled = features["stats"]?.as_bool if features["stats"]?
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
        limit: throttle_config["limit"].as_i,
        period: parse_time_span(throttle_config["period"].as_s)
      }
    end

    private def self.resolve_job_class(class_name : String) : Class
      # This will need to be implemented based on how job classes are registered
      # For now, this is a placeholder that would need runtime class resolution
      raise NotImplementedError.new("Job class resolution not yet implemented")
    end
  end
end
```

### 4. Schema Validator

```crystal
module JoobQ
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
    end

    private def self.validate_queues(queues : YAML::Any)
      queues.as_h.each do |queue_name, queue_config|
        # Validate required fields
        unless queue_config["job_class"]?
          raise ConfigValidationError.new("Queue '#{queue_name}' missing required 'job_class'")
        end

        unless queue_config["workers"]?
          raise ConfigValidationError.new("Queue '#{queue_name}' missing required 'workers'")
        end

        workers = queue_config["workers"].as_i
        raise ConfigValidationError.new("Queue '#{queue_name}' workers must be > 0") if workers <= 0

        # Validate throttle if present
        if throttle = queue_config["throttle"]?
          validate_throttle(throttle, queue_name)
        end
      end
    end

    private def self.validate_middlewares(middlewares : YAML::Any)
      valid_types = ["throttle", "retry", "timeout"]

      middlewares.as_a.each do |middleware_config|
        unless middleware_config["type"]?
          raise ConfigValidationError.new("Middleware missing required 'type' field")
        end

        type = middleware_config["type"].as_s
        unless valid_types.includes?(type)
          raise ConfigValidationError.new("Unknown middleware type: #{type}")
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
        alert_thresholds.as_h.each do |level, threshold|
          threshold_value = threshold.as_i
          raise ConfigValidationError.new("Alert threshold for '#{level}' must be > 0") if threshold_value <= 0
        end
      end
    end

    private def self.validate_schedulers(schedulers : YAML::Any)
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
      end
    end

    private def self.validate_cron_jobs(cron_jobs : YAML::Any)
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
      end
    end

    private def self.validate_recurring_jobs(recurring_jobs : YAML::Any)
      recurring_jobs.as_a.each do |recurring_job|
        unless recurring_job["interval"]?
          raise ConfigValidationError.new("Recurring job missing required 'interval' field")
        end

        unless recurring_job["job"]?
          raise ConfigValidationError.new("Recurring job missing required 'job' field")
        end

        interval = recurring_job["interval"].as_s
        validate_time_span(interval)
      end
    end

    private def self.validate_redis_config(redis_config : YAML::Any)
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
    end

    private def self.validate_time_span(time_str : String)
      unless time_str.match(/^(\d+)\s*(seconds?|minutes?|hours?|days?|weeks?|milliseconds?)$/)
        raise ConfigValidationError.new("Invalid time span format: #{time_str}")
      end
    end

    private def self.validate_timezone(timezone : String)
      begin
        Time::Location.load(timezone)
      rescue
        raise ConfigValidationError.new("Invalid timezone: #{timezone}")
      end
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
        raise ConfigValidationError.new("Invalid cron pattern: #{pattern} (must have 5 fields)")
      end

      # More detailed validation could be added here
      # For now, just check basic structure
    end
  end

  class ConfigValidationError < Exception
  end
end
```

## Configuration File Discovery & Fallback Mechanisms

### File Discovery Priority

The YAML configuration loader implements a comprehensive file discovery system with multiple fallback mechanisms:

#### 1. **Environment-Specific Files** (Highest Priority)

```bash
# These are checked first, in order:
./config/joobq.development.yml    # JOOBQ_ENV=development
./config/joobq.production.yml     # JOOBQ_ENV=production
./config/joobq.test.yml          # JOOBQ_ENV=test
./config/joobq.staging.yml       # JOOBQ_ENV=staging
```

#### 2. **Standard Project Locations**

```bash
./joobq.yml                      # Root directory
./config/joobq.yml              # Config directory
./config/joobq.yaml             # Alternative extension
./joobq.yaml                    # Alternative extension in root
```

#### 3. **Environment Variable Paths**

```bash
# Set via environment variables
export JOOBQ_CONFIG_PATH="/path/to/custom/config.yml"
export JOOBQ_CONFIG_FILE="/path/to/custom/config.yml"
```

#### 4. **User and System Locations**

```bash
~/.joobq/joobq.yml              # User home directory
/etc/joobq/joobq.yml            # System-wide configuration
```

### Fallback Strategies

#### **Strategy 1: Auto-Discovery with Defaults**

```crystal
# Automatically finds and loads configuration, falls back to defaults
config = JoobQ::YamlConfigLoader.load_auto
```

#### **Strategy 2: Environment-Specific Loading**

```crystal
# Loads environment-specific config with overrides
config = JoobQ::YamlConfigLoader.load_with_env_overrides(env: "production")
```

#### **Strategy 3: Multiple Source Merging**

```crystal
# Loads from multiple sources and merges them
sources = [
  "./config/joobq.base.yml",
  "./config/joobq.development.yml",
  "./config/joobq.local.yml"
]
config = JoobQ::YamlConfigLoader.load_from_sources(sources)
```

#### **Strategy 4: CLI Integration**

```bash
# Command line usage
joobq --config ./my-config.yml
joobq --env production
joobq -c ./config/joobq.yml -e staging
```

### Environment Variable Overrides

All configuration values can be overridden via environment variables:

```bash
# Core settings
export JOOBQ_DEFAULT_QUEUE="priority"
export JOOBQ_RETRIES="5"
export JOOBQ_TIMEOUT="30 seconds"
export JOOBQ_TIMEZONE="America/Los_Angeles"

# Pipeline settings
export JOOBQ_PIPELINE_BATCH_SIZE="200"
export JOOBQ_PIPELINE_TIMEOUT="2.0"

# Feature flags
export JOOBQ_REST_API_ENABLED="true"
export JOOBQ_STATS_ENABLED="false"

# Redis settings
export JOOBQ_REDIS_HOST="redis.example.com"
export JOOBQ_REDIS_PORT="6380"
export JOOBQ_REDIS_PASSWORD="secret"
```

### Configuration Merging Logic

When multiple configuration sources are provided, they are merged using the following rules:

1. **Base Configuration**: Starts with default values
2. **File-Based Config**: Overrides base values
3. **Environment-Specific Files**: Override general files
4. **Environment Variables**: Have final precedence

```yaml
# config/joobq.base.yml (base configuration)
joobq:
  settings:
    retries: 3
    timeout: "5 seconds"
  queues:
    default:
      job_class: "DefaultJob"
      workers: 2

---
# config/joobq.production.yml (environment-specific overrides)
joobq:
  settings:
    retries: 5
    timeout: "30 seconds"
  queues:
    priority:
      job_class: "PriorityJob"
      workers: 10

---
# Environment variables (final overrides)
export JOOBQ_RETRIES="7"
export JOOBQ_TIMEOUT="60 seconds"
```

**Result**: `retries=7`, `timeout="60 seconds"`, both queues defined.

### Error Handling & Fallbacks

#### **File Not Found**

```crystal
# Graceful fallback to defaults
begin
  config = JoobQ::YamlConfigLoader.load_from_file("missing.yml")
rescue JoobQ::ConfigFileNotFoundError
  Log.warn { "Configuration file not found, using defaults" }
  config = Configure.new
end
```

#### **Invalid YAML**

```crystal
# Clear error reporting with file context
begin
  config = JoobQ::YamlConfigLoader.load_from_file("invalid.yml")
rescue JoobQ::ConfigParseError => ex
  Log.error { "YAML parsing failed: #{ex.message}" }
  # Handle gracefully or exit
end
```

#### **Validation Errors**

```crystal
# Schema validation with detailed error messages
begin
  config = JoobQ::YamlConfigLoader.load_auto
rescue JoobQ::ConfigValidationError => ex
  Log.error { "Configuration validation failed: #{ex.message}" }
  # Provide helpful error messages to users
end
```

## Usage Examples

### Basic Usage

```crystal
# Load configuration from specific file
config = JoobQ::YamlConfigLoader.load_from_file("config/joobq.yml")

# Load configuration from string
yaml_content = File.read("config/joobq.yml")
config = JoobQ::YamlConfigLoader.load_from_string(yaml_content)

# Auto-discovery with fallback to defaults
config = JoobQ::YamlConfigLoader.load_auto

# Use with existing JoobQ setup
JoobQ.configure = config
```

### Advanced Usage

```crystal
# Environment-specific configuration
config = JoobQ::YamlConfigLoader.load_with_env_overrides(env: "production")

# Multiple source merging
config = JoobQ::YamlConfigLoader.load_from_sources([
  "./config/joobq.base.yml",
  "./config/joobq.#{ENV["RACK_ENV"]?}.yml",
  "./config/joobq.local.yml"
])

# CLI integration
config = JoobQ::YamlConfigLoader.load_from_cli_args(ARGV)
```

### Integration with Existing Code

```crystal
# Enhanced Configure class integration
module JoobQ
  class Configure
    # Add YAML loading capability to existing Configure class
    def self.load_from_yaml(path : String? = nil, env : String? = nil) : Configure
      if path
        YamlConfigLoader.load_with_env_overrides(path, env)
      else
        YamlConfigLoader.load_auto
      end
    end

    # Hybrid configuration - YAML + programmatic
    def self.load_hybrid(yaml_path : String? = nil, &block) : Configure
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
  end
end

# In your application startup
module MyApp
  def self.setup_joobq
    begin
      # Try YAML configuration first
      config = JoobQ::Configure.load_from_yaml

      # Apply any programmatic overrides if needed
      config.use do |middlewares|
        # Add custom middleware
        middlewares << MyCustomMiddleware.new
      end

      JoobQ.configure = config

    rescue ex : JoobQ::ConfigFileNotFoundError
      Log.warn { "No YAML config found, using programmatic configuration" }

      # Fallback to programmatic configuration
      JoobQ.configure do |config|
        config.queue("email", 5, EmailJob)
        config.queue("image", 3, ImageJob)
        config.queue("priority", 10, PriorityJob, {limit: 5, period: 1.minute})
      end

    rescue ex : JoobQ::ConfigValidationError
      Log.error { "Configuration validation failed: #{ex.message}" }
      raise ex
    end
  end

  # Environment-specific setup
  def self.setup_joobq_for_env(environment : String)
    config = JoobQ::Configure.load_from_yaml(env: environment)

    # Environment-specific programmatic overrides
    case environment
    when "production"
      config.worker_batch_size = 50
      config.pipeline_batch_size = 500
      config.rest_api_enabled = true
    when "development"
      config.worker_batch_size = 5
      config.rest_api_enabled = false
    when "test"
      config.retries = 1
      config.timeout = 5.seconds
    end

    JoobQ.configure = config
  end

  # CLI-based setup
  def self.setup_joobq_from_cli
    config = JoobQ::YamlConfigLoader.load_from_cli_args(ARGV)
    JoobQ.configure = config
  end
end

# Usage examples:
MyApp.setup_joobq                    # Auto-discovery
MyApp.setup_joobq_for_env("production")  # Environment-specific
MyApp.setup_joobq_from_cli          # CLI arguments
```

### Configuration File Examples

#### **Development Configuration** (`config/joobq.development.yml`)

```yaml
joobq:
  settings:
    default_queue: "development"
    retries: 1
    timeout: "5 seconds"
    timezone: "America/New_York"

  queues:
    email:
      job_class: "EmailJob"
      workers: 2
      throttle:
        limit: 10
        period: "1 minute"

    image:
      job_class: "ImageProcessingJob"
      workers: 1

  middlewares:
    - type: "retry"
    - type: "timeout"

  error_monitoring:
    alert_thresholds:
      error: 5
      warn: 10
    time_window: "2 minutes"
    max_recent_errors: 50

  features:
    rest_api: false
    stats: true

  redis:
    host: "localhost"
    port: 6379
    pool_size: 10
```

#### **Production Configuration** (`config/joobq.production.yml`)

```yaml
joobq:
  settings:
    default_queue: "default"
    retries: 5
    timeout: "30 seconds"
    timezone: "UTC"
    worker_batch_size: 50

  queues:
    email:
      job_class: "EmailJob"
      workers: 10
      throttle:
        limit: 100
        period: "1 minute"

    image:
      job_class: "ImageProcessingJob"
      workers: 5
      throttle:
        limit: 20
        period: "1 minute"

    priority:
      job_class: "PriorityJob"
      workers: 20

  middlewares:
    - type: "throttle"
    - type: "retry"
    - type: "timeout"

  error_monitoring:
    alert_thresholds:
      error: 10
      warn: 50
      info: 100
    time_window: "5 minutes"
    max_recent_errors: 200

  schedulers:
    - timezone: "UTC"
      cron_jobs:
        - pattern: "0 */6 * * *"
          job: "CleanupJob"
          args: {}
        - pattern: "0 0 * * *"
          job: "DailyReportJob"
          args: { report_type: "daily" }
      recurring_jobs:
        - interval: "5 minutes"
          job: "HealthCheckJob"
          args: {}

  features:
    rest_api: true
    stats: true

  redis:
    host: "redis.example.com"
    port: 6379
    password: "secret"
    pool_size: 500
    pool_timeout: 2.0

  pipeline:
    batch_size: 500
    timeout: 2.0
    max_commands: 2000
```

#### **Base Configuration** (`config/joobq.base.yml`)

```yaml
joobq:
  settings:
    expires: "7 days"
    failed_ttl: "1 hour"
    dead_letter_ttl: "30 days"

  middlewares:
    - type: "throttle"
    - type: "retry"
    - type: "timeout"

  error_monitoring:
    alert_thresholds:
      error: 10
      warn: 50
      info: 100
    time_window: "5 minutes"
    max_recent_errors: 100

  pipeline:
    batch_size: 100
    timeout: 1.0
    max_commands: 1000
```

## Migration Strategy

### Phase 1: Core Implementation

1. Add YAML dependency to `shard.yml`
2. Implement `YamlConfigLoader` and supporting classes
3. Add comprehensive test coverage
4. Update documentation

### Phase 2: Integration

1. Modify `Configure` class to support YAML loading
2. Add CLI support for YAML configuration
3. Create migration tools for existing configurations

### Phase 3: Advanced Features

1. Environment-specific configuration files
2. Configuration inheritance and overrides
3. Hot-reloading of configuration
4. Configuration validation in CI/CD

## Error Handling

### Validation Errors

- Schema validation with detailed error messages
- Type checking for all configuration values
- Range validation for numeric values
- Format validation for time spans and cron patterns

### Runtime Errors

- Graceful fallback to default configuration
- Detailed logging of configuration issues
- Support for partial configuration loading

## Testing Strategy

### Unit Tests

- Schema validation tests
- Configuration mapping tests
- Error handling tests
- Time span parsing tests

### Integration Tests

- End-to-end YAML loading tests
- Backward compatibility tests
- Performance benchmarks

### Example Test Cases

```crystal
describe "YamlConfigLoader" do
  it "loads basic configuration" do
    yaml = <<-YAML
      joobq:
        settings:
          default_queue: "test"
          retries: 5
        queues:
          test_queue:
            job_class: "TestJob"
            workers: 3
    YAML

    config = JoobQ::YamlConfigLoader.load_from_string(yaml)
    config.default_queue.should eq("test")
    config.retries.should eq(5)
  end

  it "validates required fields" do
    yaml = <<-YAML
      joobq:
        queues:
          test_queue:
            job_class: "TestJob"
            # missing workers
    YAML

    expect_raises(JoobQ::ConfigValidationError, "missing required 'workers'") do
      JoobQ::YamlConfigLoader.load_from_string(yaml)
    end
  end
end
```

## Performance Considerations

### Parsing Performance

- YAML parsing is done once at startup
- Minimal runtime overhead after initial load
- Efficient memory usage for configuration storage

### Validation Performance

- Schema validation runs once during load
- No runtime validation overhead
- Early failure for invalid configurations

## Security Considerations

### File Access

- Safe file path handling
- Proper error handling for missing files
- No arbitrary file inclusion

### Configuration Validation

- Strict type checking
- Range validation for all numeric values
- Pattern validation for strings

## Future Enhancements

### Advanced Features

1. **Environment Variables**: Support for environment variable substitution
2. **Configuration Inheritance**: Base configuration with environment-specific overrides
3. **Hot Reloading**: Runtime configuration updates
4. **Configuration Templates**: Reusable configuration snippets
5. **External Sources**: Load configuration from databases or APIs

### Integration Improvements

1. **IDE Support**: YAML schema for better editor support
2. **Documentation Generation**: Auto-generate configuration documentation
3. **Migration Tools**: Convert existing Crystal configurations to YAML
4. **Validation CLI**: Standalone configuration validation tool

## Conclusion

This YAML configuration loader provides a comprehensive, type-safe, and flexible way to configure the JoobQ job queue system. It maintains backward compatibility while offering a more declarative and maintainable configuration approach. The implementation follows Crystal best practices and provides extensive validation and error handling.

The design is extensible and can be enhanced with additional features as needed, while maintaining the core principles of type safety, performance, and ease of use.
