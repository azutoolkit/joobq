module JoobQ
  class Scheduler
    record RecurringJobs, job : Job, queue : String, interval : Time::Span | CronParser

    getter jobs = {} of String => RecurringJobs | CronParser
    private getter store : Store = JoobQ.store

    def self.instance
      @@instance ||= new
    end

    def clear
      @periodic_jobs.clear
    end

    def delay(job : JoobQ::Job, for till : Time::Span)
      store.schedule(job, delay_in_ms: till.from_now.to_unix_ms)
    end

    def every(interval : Time::Span, job : JoobQ::Job.class, **args)
      job_instance = job.new **args
      @jobs[job.name] = RecurringJobs.new job_instance, job_instance.queue, interval

      spawn do
        loop do
          sleep interval
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
          enqueue
          sleep 3.seconds
        end
      end
    rescue ex : Exception
      Log.error &.emit("Scheduler Crashed", reason: ex.message)
      run
    end

    def enqueue(current_time = Time.local)
      results = store.fetch_due_jobs(current_time)
      results.as(Array).each do |data|
        next unless data.is_a?(String)
        job_json = JSON.parse(data.as(String))
        queue_name = job_json["queue"].as_s
        queue = JoobQ.queues[queue_name]
        queue.add data.as(String)
      end
    end
  end
end
