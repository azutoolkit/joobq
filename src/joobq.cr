require "redis"
require "json"
require "uuid"
require "uuid/json"
require "log"
require "cron_parser"
require "./joobq/**"

module JoobQ
  VERSION = "0.1.0"
  REDIS   = Redis::PooledClient.new(
    host: ENV.fetch("REDIS_HOST", "localhost"),
    port: ENV.fetch("REDIS_PORT", "6379").to_i,
    pool_size: ENV.fetch("REDIS_POOL_SIZE", "50").to_i,
    pool_timeout: ENV.fetch("REDIS_TIMEOUT", "0.2").to_f
  )

  Log.setup_from_env(default_level: :trace)

  def self.queues
    QUEUES
  end

  def self.statistics
    Statistics.instance
  end

  def self.redis
    REDIS
  end

  def self.scheduler
    Scheduler.instance
  end

  def self.[](name : String)
    QUEUES[name]
  end

  def self.reset
    REDIS.del Status::Busy.to_s,
      Status::Completed.to_s,
      Sets::Delayed.to_s,
      Sets::Failed.to_s,
      Sets::Retry.to_s,
      Sets::Dead.to_s
  end

  def self.forge
    Log.info { "JoobQ booting..." }

    Statistics.create_series
    scheduler.run

    queues.each do |key, queue|
      Log.info { "JoobQ starting #{key} queue..." }
      queue.start
    end

    Log.info { "JoobQ initialized and waiting for Jobs..." }

    sleep
  end
end
