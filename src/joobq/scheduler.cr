module JoobQ

  class Scheduler
    record RecurringJob, interval : Time::Span, job : String, args : String do
      def to_h
        {
          "interval" => @interval.to_s,
          "job" => @job,
          "args" => @args,
        }
      end
    end
    record CronJob, pattern : String, timezone : Time::Location, next_run : String, block : Proc(Nil) do
      def next_run(next_time : Time)
       @next_run = next_time.to_rfc3339
      end

      def to_h
        {
          "pattern" => @pattern,
          "timezone" => @timezone.to_s,
          "next_run" => @next_run.to_s,
        }
      end
    end

     getter cron_scheduler : CronJobScheduler
     getter delayed_scheduler : DelayedJobScheduler
     getter recurring_scheduler : RecurringJobScheduler
    private getter store : Store
    private getter time_location : Time::Location
    private getter delay_set : String

    # Singleton instance
    def initialize(
      @time_location : Time::Location = JoobQ.config.time_location,
      @store : Store = RedisStore.instance,
      @delay_set : String = RedisStore::DELAYED_SET)

      @delayed_scheduler = DelayedJobScheduler.new(store)
      @recurring_scheduler = RecurringJobScheduler.new
      @cron_scheduler = CronJobScheduler.new
    end

    def jobs
      cron_scheduler.jobs.merge(recurring_scheduler.jobs)
    end

    # Class methods for job registration
    def delay(job : Job, delay_time : Time::Span)
      delayed_scheduler.delay(job, delay_time)
    end

    def every(interval : Time::Span, job : Job.class, **args)
      recurring_scheduler.every(interval, job, **args)
    end

    def cron(pattern : String, &block : ->)
      cron_scheduler.cron(pattern, @time_location, &block)
    end

    def enqueue(time : Time::Span)
      delayed_scheduler.enqueue(time)
    end

    def run
      Log.info &.emit("Scheduler starting...")
      spawn do
        loop do
          enqueue_due_jobs
          sleep 120.seconds
        end
      end
    rescue ex : Exception
      Log.error &.emit("Scheduler crashed", reason: ex.message)
      run
    end

    def enqueue_due_jobs(current_time = Time.local)
      results = store.fetch_due_jobs(current_time)

      results.each do |job_data|
        begin
          # Deserialize job and enqueue
          job_json = JSON.parse(job_data)
          queue_name = job_json["queue"]
          queue = JoobQ.queues[queue_name]
          queue.add(job_data)
        rescue ex : Exception
          Log.error &.emit("Failed to enqueue job", data: job_data, reason: ex.message)
        end
      end
    end
  end
end
