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
  CONFIG = Configure.new

  def self.config
    CONFIG
  end

  def self.configure(&)
    with CONFIG yield CONFIG
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
