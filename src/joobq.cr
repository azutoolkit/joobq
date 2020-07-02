require "redis"
require "json"
require "uuid"
require "uuid/json"
require "log"
require "cron_parser"
require "./joobq/**"

module JoobQ
  VERSION       = "0.1.0"
  class_property workers_capacity = 1
  LOADER_QUEUES = {} of Nil => Nil
  REDIS = Redis::PooledClient.new(
    host: ENV.fetch("REDIS_HOST", "localhost"),
    port: ENV.fetch("REDIS_PORT", "6379").to_i,
    pool_size: ENV.fetch("REDIS_POOL_SIZE", "50").to_i,
    pool_timeout: ENV.fetch("REDIS_POOL_SIZE", "0.5").to_f
  )

  Log.setup_from_env(default_level: :trace)

  def self.[](name : String)
    QUEUES[name]
  end

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

  def self.reset
    REDIS.del Queues::Busy.to_s,
      Queues::Completed.to_s,
      Sets::Dead.to_s,
      Sets::Retry.to_s,
      Sets::Dead.to_s
  end

  def self.forge
    Log.info { "JoobQ starting..." }
    Scheduler.instance.run

    spawn do
      loop do
        sleep rand(3)

        QUEUES.each do |_name, queue|
          spawn do
            queue.process
          end
        end
      end
    end

    Log.info { "JoobQ initialized and waiting for Jobs..." }
  end
end
