require "yaml"

module JoobQ
  # Custom exception classes for YAML configuration
  class ConfigFileNotFoundError < Exception
  end

  class ConfigParseError < Exception
  end

  class ConfigLoadError < Exception
  end

  # YAML configuration loader for JoobQ
  class YamlConfigLoader
    # Configuration file search paths (in order of precedence)
    DEFAULT_SEARCH_PATHS = [
      "./joobq.yml",
      "./config/joobq.yml",
      "./config/joobq.yaml",
      "./joobq.yaml",
      ENV["JOOBQ_CONFIG_PATH"]?,
      ENV["JOOBQ_CONFIG_FILE"]?,
      "~/.joobq/joobq.yml",
      "/etc/joobq/joobq.yml",
    ].compact

    # Environment-specific file patterns
    ENV_FILE_PATTERNS = [
      "./config/joobq.#{ENV["JOOBQ_ENV"]? || "development"}.yml",
      "./config/joobq.#{ENV["RACK_ENV"]? || "development"}.yml",
      "./config/joobq.#{ENV["CRYSTAL_ENV"]? || "development"}.yml",
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
      config = map_to_configure(config_data, source_path)

      # Validate the configuration after loading
      config.validate_configuration

      config
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
        load_with_env_overrides(env: environment)
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
          config.time_location = value
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
      merged.rest_api_enabled = base.rest_api_enabled?
      merged.stats_enabled = base.stats_enabled?
      merged.time_location = base.time_location.name

      # Merge queues (override takes precedence)
      base.queues.each { |name, queue| merged.queues[name] = queue }
      override.queues.each { |name, queue| merged.queues[name] = queue }

      # Merge middlewares (override replaces)
      if !override.middlewares.empty?
        merged.middlewares = override.middlewares
      else
        merged.middlewares = base.middlewares
      end

      # Merge error monitoring config
      if !override.error_monitor.alert_thresholds.empty?
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

      # Override store if specified (avoid default RedisStore comparison)
      merged.store = override.store unless override.store.is_a?(RedisStore)

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
end
