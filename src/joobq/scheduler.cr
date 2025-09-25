module JoobQ
  class Scheduler
    record RecurringJob, interval : Time::Span, job : String, args : String do
      def to_h
        {
          "interval" => @interval.to_s,
          "job"      => @job,
          "args"     => @args,
        }
      end
    end
    record CronJob, pattern : String, timezone : Time::Location, next_run : String, block : Proc(Nil) do
      def next_run(next_time : Time)
        @next_run = next_time.to_rfc3339
      end

      def to_h
        {
          "pattern"  => @pattern,
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
      @delay_set : String = RedisStore::DELAYED_SET
    )
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
      Log.info { "Scheduler starting..." }
      spawn do
        loop do
          enqueue_due_jobs
          sleep 5.seconds
        end
      end
    rescue ex : Exception
      Log.error &.emit("Scheduler crashed", reason: ex.message)
      run
    end

    def enqueue_due_jobs(current_time = Time.local)
      results = store.fetch_due_jobs(current_time, @delay_set)

      results.each do |job_data|
        begin
          # Deserialize job and enqueue
          job_json = JSON.parse(job_data)
          queue_name = job_json["queue"]
          queue = JoobQ.queues[queue_name]
          queue.add(job_data)
        rescue ex : Exception
          handle_scheduler_error(ex, job_data, current_time)
        end
      end
    end

    private def handle_scheduler_error(ex : Exception, job_data : String, current_time : Time)
      error_context = {
        scheduler: "delayed_jobs",
        error_class: ex.class.name,
        error_message: ex.message || "Unknown error",
        job_data_length: job_data.size.to_s,
        current_time: current_time.to_rfc3339,
        delay_set: @delay_set,
        occurred_at: Time.local.to_rfc3339
      }.to_h

      case ex
      when KeyError
        additional_context = {
          queue_name: "unknown",
          available_queues: JoobQ.queues.keys.join(",")
        }.to_h
        Log.error &.emit("Queue not found for delayed job", error_context.merge(additional_context))
      when JSON::Error
        Log.error &.emit("Invalid job data in delayed queue", error_context)
        # Could potentially move to dead letter queue
        move_to_dead_letter(job_data, "invalid_json")
      when Redis::CannotConnectError
        Log.error &.emit("Redis connection failed in scheduler", error_context)
        raise ex # Re-raise critical errors
      else
        Log.error &.emit("Unexpected error in scheduler", error_context)
      end
    end

    private def move_to_dead_letter(job_data : String, reason : String)
      begin
        # Try to parse job to get basic info
        job_json = JSON.parse(job_data)
        job_id = job_json["jid"]? || "unknown"

        Log.warn &.emit(
          "Moving invalid job to dead letter",
          job_id: job_id.to_s,
          reason: reason,
          job_data_length: job_data.size.to_s
        )

        # Cannot store corrupted job data in dead letter
        # Just log the error since we can't create a valid Job object
        Log.error &.emit(
          "Cannot move corrupted job to dead letter - data is unparseable",
          reason: reason,
          job_data_length: job_data.size.to_s,
          job_id: job_id.to_s
        )
      rescue
        # If we can't even parse the job, just log it
        Log.error &.emit(
          "Could not process corrupted job data",
          reason: reason,
          job_data_length: job_data.size.to_s
        )
      end
    end
  end
end
