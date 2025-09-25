require "redis"
require "json"
require "uuid"
require "uuid/json"
require "log"
require "cron_parser"
require "./joobq/store"
require "./joobq/error_context"
require "./joobq/error_monitor"
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

  def self.forge
    Log.info { "JoobQ starting..." }

    config.schedulers.each do |scheduler|
      scheduler.run
    end

    queues.each do |key, queue|
      Log.info { "JoobQ starting #{key} queue..." }
      queue.start
    end

    Scheduler.new(delay_set: RedisStore::FAILED_SET).run

    Log.info { "JoobQ initialized and waiting for Jobs..." }

    Log.info { "Rest API Enabled: #{config.rest_api_enabled?}" }
    if config.rest_api_enabled?
      APIServer.start
    end

    sleep
  end
end
