module JoobQ
  module DeadLetter
    DEAD_LETTER = Sets::Dead.to_s
    REDIS       = JoobQ.redis

    def self.add(job)
      now = Time.local.to_unix_f
      expires = (Time.local - 6.months).to_unix_f

      REDIS.zadd DEAD_LETTER, now, job.jid.to_s
      REDIS.zremrangebyscore DEAD_LETTER, "-inf", expires
      REDIS.zremrangebyrank DEAD_LETTER, 0, -10_000
    end
  end
end
