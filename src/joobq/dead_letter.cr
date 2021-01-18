module JoobQ
  module DeadLetter
    DEAD_LETTER = Sets::Dead.to_s
    REDIS       = JoobQ::REDIS

    def self.add(job)
      now = Time.local.to_unix_f
      expires = (Time.local - 3.days).to_unix_f

      REDIS.pipelined do |p|
        p.zadd DEAD_LETTER, now, job.jid.to_s
        p.zremrangebyscore DEAD_LETTER, "-inf", expires
        p.zremrangebyrank DEAD_LETTER, 0, -10_000
      end
    end
  end
end
