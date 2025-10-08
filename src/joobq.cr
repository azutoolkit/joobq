require "redis"
require "json"
require "uuid"
require "uuid/json"
require "log"
require "cron_parser"
require "./joobq/store"
require "./joobq/error_context"
require "./joobq/error_monitor"
require "./joobq/api_validation"
require "./joobq/api_cache"
require "./joobq/**"

module JoobQ
  # Configuration instance with lazy loading
  @@config : Configure? = nil
  @@config_initialized = false

  def self.config : Configure
    initialize_config unless @@config_initialized
    @@config.not_nil!
  end

  def self.configure(&)
    with config yield config
  end

  # Initialize configuration with auto-discovery
  def self.initialize_config : Nil
    return if @@config_initialized

    @@config = load_auto
    @@config_initialized = true
    Log.info { "JoobQ configuration initialized with auto-discovery" }
  end

  # Initialize configuration with specific loading method
  def self.initialize_config_with(loading_method : Symbol, *args, **kwargs) : Nil
    return if @@config_initialized

    case loading_method
    when :yaml
      @@config = load_from_yaml(*args, **kwargs)
    when :file
      # load_from_file only takes a path argument
      path = args.first?.to_s || raise ArgumentError.new("File path required for :file loading method")
      @@config = load_from_file(path)
    when :string
      # load_from_string takes content and optional source_path
      content = args.first?.to_s || raise ArgumentError.new("YAML content required for :string loading method")
      source_path = args[1]?.to_s
      @@config = load_from_string(content, source_path)
    when :sources
      # Convert args to Array(String) for sources
      sources = Array(String).new
      args.each { |arg| sources << arg.to_s }
      @@config = load_from_yaml_sources(sources)
    when :cli_args
      # Convert args to Array(String) for CLI args
      cli_args = Array(String).new
      args.each { |arg| cli_args << arg.to_s }
      @@config = load_from_cli_args(cli_args)
    when :env_overrides
      @@config = load_with_env_overrides(*args, **kwargs)
    else
      raise ArgumentError.new("Unknown loading method: #{loading_method}")
    end

    @@config_initialized = true
    Log.info { "JoobQ configuration initialized with #{loading_method}" }
  end

  # Initialize configuration with hybrid loading method (requires block)
  def self.initialize_config_with(loading_method : Symbol, *args, **kwargs, &block) : Nil
    return if @@config_initialized

    case loading_method
    when :hybrid
      @@config = load_hybrid(*args, **kwargs) { |cfg| yield cfg }
    else
      raise ArgumentError.new("Loading method #{loading_method} does not support blocks")
    end

    @@config_initialized = true
    Log.info { "JoobQ configuration initialized with #{loading_method}" }
  end

  # Reset configuration (useful for testing)
  def self.reset_config : Nil
    @@config = nil
    @@config_initialized = false
    Log.info { "JoobQ configuration reset" }
  end

  # Set a custom configuration
  def self.set_config(config : Configure) : Nil
    @@config = config
    @@config_initialized = true
    Log.info { "JoobQ configuration set" }
  end

  def self.store
    config.store
  end

  def self.reset
    store.reset
  end

  def self.queues
    config.queues
  end

  def self.add(job)
    store.enqueue(job)
  end

  def self.scheduler
    Scheduler.instance
  end

  def self.[](name : String)
    queues[name]
  end

  def self.error_monitor : ErrorMonitor
    config.error_monitor
  end

  def self.api_cache : APICache
    APICache.instance
  end

  # Configuration loading methods
  def self.load_from_yaml(path : String? = nil, env : String? = nil) : Configure
    Configure.load_from_yaml(path, env)
  end

  def self.load_hybrid(yaml_path : String? = nil, &)
    Configure.load_hybrid(yaml_path) { |config| yield config }
  end

  def self.load_from_yaml_sources(sources : Array(String)) : Configure
    Configure.load_from_yaml_sources(sources)
  end

  def self.load_from_cli_args(args : Array(String)) : Configure
    Configure.load_from_cli_args(args)
  end

  def self.load_auto : Configure
    YamlConfigLoader.load_auto
  end

  def self.load_from_file(path : String) : Configure
    YamlConfigLoader.load_from_file(path)
  end

  def self.load_from_string(yaml_content : String, source_path : String? = nil) : Configure
    YamlConfigLoader.load_from_string(yaml_content, source_path)
  end

  def self.load_with_env_overrides(base_path : String? = nil, env : String? = nil) : Configure
    YamlConfigLoader.load_with_env_overrides(base_path, env)
  end

  def self.find_config_file : String?
    YamlConfigLoader.find_config_file
  end

  def self.forge
    Log.info { "JoobQ starting..." }

    config.schedulers.each do |scheduler|
      scheduler.run
    end

    # Start delayed job scheduler (processes retrying jobs from DELAYED_SET)
    config.delayed_job_scheduler.start

    queues.each do |key, queue|
      Log.info { "JoobQ starting #{key} queue..." }
      queue.start
    end

    Log.info { "JoobQ initialized and waiting for Jobs..." }

    Log.info { "Rest API Enabled: #{config.rest_api_enabled?}" }
    if config.rest_api_enabled?
      APIServer.start
    end

    sleep
  end
end
