module JoobQ
  module Failed
    FAILED_SET = Sets::Failed.to_s
    REDIS      = JoobQ.redis

    def self.add(job, ex)
      now = Time.local
      expires = (Time.local - 3.days).to_unix_f

      error = {
        queue:     job.queue,
        failed_at: now,
        message:   ex.message,
        backtrace: ex.inspect_with_backtrace,
        cause:     ex.cause.to_s,
      }

      Log.error &.emit("Error", error)

      key = "#{FAILED_SET}:#{job.jid}"

      REDIS.zadd key, now.to_unix_f, error.to_json
      REDIS.zremrangebyscore key, "-inf", expires
      REDIS.zremrangebyrank key, 0, -10_000
    end
  end
end
