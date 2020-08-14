module JoobQ
  class Statistics
    INSTANCE         = new
    RETENTION_MILLIS = 10800000
    STATS_KEY        = "stats"

    def self.instance
      INSTANCE
    end

    getter redis : Redis::PooledClient = JoobQ.redis

    def queues
      QUEUES
    end

    def queues_details
      queues.map do |k,q|
        {
          name: q.name, 
          total_workers: q.total_workers,
          jobs: q.jobs,
          status: q.status,
          running_workers: q.running_workers,
          size: q.size,
        }
      end
    end

    def query(from, to, filters, aggr = "avg", group_by = 5000, count = 100)
      q = ["TS.MRANGE", "#{from}", "#{to}"]

      q << "COUNT"
      q << "#{count}"
      q << "AGGREGATION"
      q << "#{aggr}"
      q << "#{group_by}"
      q << "FILTER"
      q << "#{filters}"

      result_set(redis.command q)
    end

    def result_set(results)
      results.not_nil!.as(Array)[0].as(Array)[2].as(Array)
    rescue
      [] of Array(Int64 | String)
    end

    def failed(key : String)
      redis.keys key
    end

    def count_stats
      result = jobs_count_by_status
      total = sum_of_jobs(result)

      {
        total:        total,
        busy:         result[0],
        completed:    result[1],
        delayed:      result[2],
        retry:        result[3],
        dead:         result[4],
        failed:       result[5],
        busy_percent:       percent_of(result[0], total),
        completed_percent:  percent_of(result[1], total),
        delayed_percent:    percent_of(result[2], total),
        retry_percent:      percent_of(result[3], total),
        dead_percent:       percent_of(result[4], total),
        failed_percent:     percent_of(result[5], total),
      }
    end

    def percent_of(quotient, divisor)
      (( quotient / divisor ) * 100).round || 0.0
    end

    def sum_of_jobs(result)
      result.reduce(0) { |acc, v| acc += v.as(Int64) }
    end

    def jobs_count_by_status
      redis.pipelined do |pipe|
        pipe.llen(Queues::Busy.to_s)
        pipe.llen(Queues::Completed.to_s)
        pipe.zcard(Sets::Delayed.to_s)
        pipe.zcard(Sets::Retry.to_s)
        pipe.zcard(Sets::Dead.to_s)
        pipe.zcard(Sets::Failed.to_s)
      end.map do |v|
        v.as(Int64)
      end
    end

    def create_key(key_name = STATS_KEY)
      queues.each do |name, q|
        q.workers.each do |w|
          begin
            redis.command [
              "TS.CREATE",
              "#{STATS_KEY}:#{q.name}",
              "RETENTION", "#{RETENTION_MILLIS}",
              "LABELS",
              "name", "#{q.name}",
              "wid", "#{w.wid}",
            ]
          rescue e
          end
        end
      end
      "OK"
    end

    def reset
      queues.each do |name, q|
        q.workers.each do |w|
          redis.del "#{STATS_KEY}:#{q.name}:#{w.wid}"
        end
      end
    end

    def track(name : String, wid : Int32, latency : Int32)
      redis.command ["TS.ADD", "#{STATS_KEY}:#{name}", "*", "#{latency}", "LABELS", "name", "#{name}"]
    rescue e
      -1
    end
  end
end
