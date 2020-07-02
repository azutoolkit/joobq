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

    def count_stats
      result = redis.pipelined do |pipe|
        pipe.llen(Queues::Busy.to_s)
        pipe.llen(Queues::Completed.to_s)
        pipe.zcard(Sets::Delayed.to_s)
        pipe.zcard(Sets::Retry.to_s)
        pipe.zcard(Sets::Dead.to_s)
      end

      {
        busy:      result[0].as(Int64),
        completed: result[1].as(Int64),
        delayed:   result[2].as(Int64),
        retry:     result[3].as(Int64),
        dead:      result[4].as(Int64),
      }
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
