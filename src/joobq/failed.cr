module JoobQ
  module Failed
    FAILED_SET = Sets::Failed.to_s
    REDIS = JoobQ.redis

    def self.add(job, ex)
      key = "#{FAILED_SET}:#{job.queue}:#{job.jid}"
      REDIS.setex key, 2.days.total_seconds.to_i, ex.to_s
    end
  end
end
