module JoobQ
  class Scheduler
    INSTANCE = new

    getter redis : Redis::PooledClient = JoobQ::REDIS
    getter periodic_jobs = {} of String => CronParser
    getter delayed_queue : String = Sets::Delayed.to_s

    def self.instance
      INSTANCE
    end

    def clear
      @periodic_jobs.clear
    end

    def register(&block)
      with self yield
    end

    def delay(job : JoobQ::Job, till : Time::Span)
      redis.zadd(delayed_queue, till.from_now.to_unix_f, job.to_json)
    end

    def run
      spawn do
        loop do
          sleep 1
          enqueue
        end
      end
    end

    def enqueue(now = Time.monotonic)
      moment = "%.6f" % now.to_unix_f

      results = redis.zrangebyscore(
        delayed_queue, "-inf", moment, limit: [0, 10]
      )

      if results.is_a?(Array)
        results.as(Array).each do |data|
          next unless data.is_a?(String)
          _data = data.as(String)
          job = JSON.parse(_data)

          queue = JoobQ[job["queue"].as_s]

          Log.info &.emit("Enqueue", queue: job["queue"].to_s, job_id: job["jid"].to_s)

          if redis.zrem(delayed_queue, _data)
            queue.push _data
          end
        end
      end
    end

    def at(pattern, name = nil, &block : ->)
      parser = CronParser.new(pattern)
      @periodic_jobs[(name || pattern).to_s] = parser

      spawn do
        prev_nxt = Time.monotonic - 1.minute
        loop do
          now = Time.local
          nxt = parser.next(now)
          nxt = parser.next(nxt) if nxt == prev_nxt
          prev_nxt = nxt
          # Todo: Push job to history of runs
          sleep(nxt - now)
          spawn { block.call }
        end
      end
    end

    def stats
      @periodic_jobs.map do |k, v|
        nxt = v.next
        {:name => k, :next_execution_at => nxt, :sleeping_for => (nxt - Time.local).to_f}
      end
    end
  end
end
