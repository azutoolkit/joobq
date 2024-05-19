module JoobQ
  class Scheduler
    record RecurringJobs, job : Job, queue : String, interval : Time::Span | CronParser

    getter jobs = {} of String => RecurringJobs | CronParser
    getter delayed_queue : String = Sets::Delayed.to_s

    def self.instance
      @@instance ||= new
    end

    def clear
      @periodic_jobs.clear
    end

    def delay(job : JoobQ::Job, for till : Time::Span)
      store.delay_add(job, till)
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

      job_instance
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

      results = store.get_delayed(now)

      if results.is_a?(Array)
        results.as(Array).each do |data|
          next unless data.is_a?(String)
          _data = data.as(String)
          job = JSON.parse(_data)
          job_id = job["jid"].as(String)
          queue_name = job["queue"].as(String)
          queue = JoobQ[queue_name]

          Log.info &.emit("Enqueue", queue: queue_name, job_id: job_id)

          if store.remove_delayed(_data, delayed_queue)
            job["status"] = :enqueued
            queue.push _data
          end
        end
      end
    end
  end
end
