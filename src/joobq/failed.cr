module JoobQ
  module Failed
    FAILED_SET = Sets::Failed.to_s
    REDIS = JoobQ.redis

    def self.add(job, ex)
      now = Time.local.to_unix_f
      expires = (Time.local - 6.months).to_unix_f
      job.retries = job.retries - 1
      job.ex = {
        "message" => ex.message, 
        "backtrace"=> ex.inspect_with_backtrace,
        "cause" => ex.cause.to_s,
      }
      key = "#{FAILED_SET}:#{job.queue}:#{job.jid}"
      REDIS.zadd key, now, job.to_json
      REDIS.zremrangebyscore key, "-inf", expires
      REDIS.zremrangebyrank key, 0, -10_000
    end
  end
end
