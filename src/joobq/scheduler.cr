module JoobQ
  class Scheduler
    INSTANCE = new

    getter redis : Redis::PooledClient = JoobQ.redis
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
          sleep 100.milliseconds
          enqueue(Time.local)
        end
      end
    end

    def enqueue(now = Time.local)
      loop do
        moment = "%.6f" % now.to_unix_f

        results = redis.zrangebyscore(
          delayed_queue, "-inf", moment, limit: [0, 1]
        ).as(Array)

        break if results.empty?

        data = results.first.as(String)
        job = JSON.parse(data)

        Log.info &.emit("Enqueueing Job", queue: job["queue"].to_s, job_id: job["jid"].to_s)

        if redis.zrem(delayed_queue, data)
          redis.rpush(job["queue"].as_s, data)
        end
      end
    end

    def at(pattern, name = nil, &block : ->)
      parser = CronParser.new(pattern)
      @periodic_jobs[(name || pattern).to_s] = parser

      spawn do
        prev_nxt = Time.local - 1.minute
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
