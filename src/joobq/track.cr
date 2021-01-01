module JoobQ
  module Track
    extend self
    REDIS = JoobQ.redis

    def success(job, start)
      REDIS.pipelined do |pipe|
        pipe.command ["TS.ADD", "stats:#{job.queue}:success", "*", "#{latency(start)}"]
        pipe.lpush(Status::Completed.to_s, "#{job.jid}")
        pipe.lrem(Status::Busy.to_s, -1, "#{job.jid}")
      end
    end

    def self.processed(job, start)
      REDIS.pipelined do |pipe|
        pipe.command ["TS.ADD", "stats:processing", "*", "#{latency(start)}"]
        pipe.lrem(Status::Busy.to_s, 0, "#{job.jid}")
      end
    end

    def self.failure(job, start, ex)
      FailHandler.call job, latency(start), ex
    end

    private def latency(start)
      (Time.monotonic - start).milliseconds
    end
  end
end
