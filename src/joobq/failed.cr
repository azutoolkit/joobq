module JoobQ
  module FailHandler
    extend self

    FAILED_SET = Sets::Failed.to_s
    REDIS      = JoobQ.redis

    def call(job, latency, ex : Exception)
      track job, latency, ex

      if job.retries > 0
        Retry.attempt job
      else
        DeadLetter.add job
      end
    end

    def track(job, latency, ex)
      now = Time.local
      expires = (Time.local - 3.days).to_unix_f
      key = "#{FAILED_SET}:#{job.jid}"
      error = {
        queue:     job.queue,
        failed_at: now,
        message:   ex.message,
        backtrace: ex.inspect_with_backtrace,
        cause:     ex.cause.to_s,
      }

      Log.error &.emit("Error", error)

      REDIS.pipelined do |pipe|
        pipe.command ["TS.ADD", "stats:#{job.queue}:error", "*", "#{latency}"]
        pipe.setex "jobs:#{job.jid}", job.expires, job.to_json
        pipe.lrem(Status::Busy.to_s, 0, job.jid.to_s)
        pipe.lpush(Status::Retry.to_s, job.jid.to_s)
        pipe.zadd key, now.to_unix_f, error.to_json
        pipe.zremrangebyscore key, "-inf", expires
        pipe.zremrangebyrank key, 0, -10_000
      end
    end
  end
end
