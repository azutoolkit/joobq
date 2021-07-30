require "redis"
require "json"
require "uuid"
require "uuid/json"
require "log"
require "cron_parser"
require "./joobq/**"

module JoobQ
  REDIS = Configure::INSTANCE.redis

  Log.setup_from_env(default_level: :trace)

  def self.configure
    with Configure::INSTANCE yield
  end

  def self.queues
    Configure::INSTANCE.queues
  end

  def self.statistics
    Statistics.instance
  end

  def self.push(job)
    JoobQ::REDIS.pipelined do |p|
      p.setex "jobs:#{job.jid}", job.expires || 180, job.to_json
      p.rpush job.queue, "#{job.jid}"
    end
    job.jid
  end

  def self.scheduler
    Scheduler.instance
  end

  def self.[](name : String)
    queues[name]
  end

  def self.reset
    queues.each { |key, _| REDIS.del key }

    REDIS.del Status::Busy.to_s,
      Status::Completed.to_s,
      Sets::Delayed.to_s,
      Sets::Failed.to_s,
      Sets::Retry.to_s,
      Sets::Dead.to_s

    Statistics.create_series
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
