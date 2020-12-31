module JoobQ
  class Statistics
    INSTANCE         = new
    RETENTION_MILLIS = 10800000
    STATS_KEY        = "stats"
    STATS            = %w[Errors Retries Dead Success Latency]
    REDIS            = JoobQ.redis

    def self.instance
      INSTANCE
    end

    def self.record_success(name, job_id, latency)
      REDIS.pipelined do |pipe|
        pipe.command ["TS.ADD", "stats:#{name}:success", "*", "#{latency}"]
        pipe.command ["TS.ADD", "stats:processing", "*", "#{latency}"]
        pipe.lpush(Queues::Completed.to_s, job_id)
        pipe.lrem(Queues::Busy.to_s, 0, job_id)
      end
    end

    def self.record_failure(name, latency)
      REDIS.command ["TS.ADD", "stats:#{name}:error", "*", "#{latency}"]
    end

    def self.create_series
      instance.create_key "processing"

      JoobQ::QUEUES.each do |key, _|
        instance.create_key key
      end
    end

    def queues
      JoobQ::QUEUES
    end

    def queue(name)
      q = queues[name]
      {
        name:          q.name,
        total_workers: q.total_workers,
        jobs:          q.jobs,
        status:        q.status,
        size:          q.size,
      }
    end

    def queues_details
      queues.map do |_, q|
        {
          name:          q.name,
          total_workers: q.total_workers,
          jobs:          q.jobs,
          status:        q.status,
          size:          q.size,
          # failed: redis.zscan(Sets::Failed.to_s, 0, "#{q.name}*", count = nil),
          # retry: redis.zscan(Sets::Retry.to_s, 0, "#{q.name}*", count = nil),
          # errors: query(1.hour.ago.to_unix_ms, 1.hour.from_now.to_unix_ms, "count", 60000, 100),
          # latency: query(1.hour.ago.to_unix_ms, 1.hour.from_now.to_unix_ms, "avg", 60000, 100),
          # completed: query(1.hour.ago.to_unix_ms, 1.hour.from_now.to_unix_ms, "avg", 60000, 100),
        }
      end
    end

    def reset
      queues.each do |_, q|
        REDIS.del "#{STATS_KEY}:#{q.name}"
      end
    end

    def range(name, since = 0, to = 1.hour.from_now.to_unix_ms, aggr = "count", group = 5000, count = 100)
      q = ["TS.RANGE", key(name), "#{since}", "#{to}"]

      q << "COUNT"
      q << "#{count}"
      q << "AGGREGATION"
      q << "#{aggr}"
      q << "#{group}"

      result_set REDIS.command(q)
    end

    def totals
      result = jobs_count_by_status
      total = result[0] + result[1] + result[2]

      {
        total:     total,
        completed: result[0],
        retry:     result[1],
        dead:      result[2],
        busy:      result[3],
        delayed:   result[4],

        completed_percent: percent_of(result[0], total),
        retry_percent:     percent_of(result[1], total),
        dead_percent:      percent_of(result[2], total),
        busy_percent:      percent_of(result[4], total),
      }
    end

    private def key(name)
      "#{STATS_KEY}:#{name}"
    end

    private def result_set(results)
      results.not_nil!.as(Array(Redis::RedisValue))
    rescue
      [] of Array(Int64 | String)
    end

    private def percent_of(quotient, divisor)
      ((quotient / divisor) * 100).round || 0.0
    end

    private def jobs_count_by_status
      REDIS.pipelined do |pipe|
        pipe.llen(Queues::Completed.to_s)
        pipe.zcard(Sets::Retry.to_s)
        pipe.zcard(Sets::Dead.to_s)
        pipe.llen(Queues::Busy.to_s)
        pipe.zcard(Sets::Delayed.to_s)
      end.map do |v|
        v.as(Int64)
      end
    end

    def create_key(name)
      REDIS.command [
        "TS.CREATE",
        "#{STATS_KEY}:#{name}",
        "RETENTION", "#{RETENTION_MILLIS}",
        "LABELS",
        "name", "#{name}",
        "stats", "stats",
      ]
      "Ok!"
    rescue
      "Key already exists. Ok!"
    end
  end
end
