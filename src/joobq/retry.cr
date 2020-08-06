module JoobQ
  module Retry
    RETRY_SET = Sets::Retry.to_s
    REDIS = JoobQ.redis

    def self.attempt(job)
      count = job.retries
      job.retries = job.retries - 1
      retry_time = retry_at(count).to_unix_f

      REDIS.zadd RETRY_SET, retry_time, job.to_json
    end

    private def self.retry_at(count : Int32)
      Time.local + ((count ** 4) + 15 + (rand(30)*(count + 1))).seconds
    end
  end
end
