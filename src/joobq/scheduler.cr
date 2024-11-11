module JoobQ
  class Scheduler
    record RecurringJobs, job : Job, queue : String, interval : Time::Span | CronParser

    private getter jobs = {} of String => RecurringJobs | CronParser
    private getter delayed_queue : String = Sets::Delayed.to_s
    private getter store : Store = JoobQ.store

    def self.instance
      @@instance ||= new
    end

    def clear
      @periodic_jobs.clear
    end

    def delay(job : JoobQ::Job, for till : Time::Span)
      store.add_delayed(job, till)
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
          sleep 0.5.seconds
          enqueue
        end
      end
    end

    def enqueue(now = Time.local)
      results = store.get_delayed(now)

      if results.is_a?(Array)
        results.as(Array).each do |data|
          next unless data.is_a?(String)

          if store.remove_delayed(data)
            job_json = JSON.parse(data.as(String))
            queue_name = job_json["queue"].as_s
            queue = JoobQ.queues[queue_name]
            queue.push data.as(String)
          end
        end
      end
    end
  end
end
