module JoobQ
  class Scheduler
    INSTANCE = new
    REDIS    = JoobQ::REDIS

    record RecurringJobs, job : Job, queue : String, interval : Time::Span | CronParser

    getter jobs = {} of String => RecurringJobs | CronParser
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

    def delay(job : JoobQ::Job, for till : Time::Span)
      REDIS.zadd(delayed_queue, till.from_now.to_unix_f, job.to_json)
    end

    def every(interval : Time::Span, job : JoobQ::Job.class, **args)
      job_instance = job.new **args
      @jobs[job.name] = RecurringJobs.new job_instance, job_instance.queue, interval

      spawn do
        loop do
          sleep interval.total_seconds
          spawn { job_instance.perform }
        end
      end
    end

    def cron(pattern, &block : ->)
      parser = CronParser.new(pattern)
      @jobs[pattern] = parser
      spawn do
        prev_nxt = Time.monotonic - 1.minute

        loop do
          now = Time.local
          nxt = parser.next(now)
          nxt = parser.next(nxt) if nxt == prev_nxt
          prev_nxt = nxt
          sleep(nxt - now)
          spawn { block.call }
        end
      end
    end

    def run
      spawn do
        loop do
          sleep 1
          enqueue
        end
      end
    end

    def enqueue(now = Time.local)
      moment = "%.6f" % now.to_unix_f

      results = REDIS.zrangebyscore(
        delayed_queue, "-inf", moment, limit: [0, 10]
      )

      if results.is_a?(Array)
        results.as(Array).each do |data|
          next unless data.is_a?(String)
          _data = data.as(String)
          job = JSON.parse(_data)

          queue = JoobQ[job["queue"].as_s]

          Log.info &.emit("Enqueue", queue: job["queue"].to_s, job_id: job["jid"].to_s)

          if REDIS.zrem(delayed_queue, _data)
            queue.push _data
          end
        end
      end
    end
  end
end
