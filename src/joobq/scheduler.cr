module JoobQ
  class Scheduler
    private getter delayed_scheduler : DelayedJobScheduler
    private getter recurring_scheduler : RecurringJobScheduler
    private getter cron_scheduler : CronJobScheduler
    private getter store : Store
    private getter time_location = JoobQ.config.time_location

    # Singleton instance
    def initialize(@timezone : Time::Location, @store : Store = RedisStore.instance)
      @delayed_scheduler = DelayedJobScheduler.new(store)
      @recurring_scheduler = RecurringJobScheduler.new
      @cron_scheduler = CronJobScheduler.new
    end

    # Class methods for job registration
    def delay(job : Job, delay_time : Time::Span)
      delayed_scheduler.delay(job, delay_time)
    end

    def every(interval : Time::Span, job : Job.class, **args)
      recurring_scheduler.every(interval, job, **args)
    end

    def cron(pattern : String, &block : ->)
      cron_scheduler.cron(pattern, @timezone, &block)
    end

    def run
      Log.info &.emit("Scheduler starting...")
      spawn do
        loop do
          enqueue_due_jobs
          sleep 3.seconds
        end
      end
    rescue ex : Exception
      Log.error &.emit("Scheduler crashed", reason: ex.message)
      run
    end

    private def enqueue_due_jobs
      current_time = Time.local
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
