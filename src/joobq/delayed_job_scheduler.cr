module JoobQ
  class DelayedJobScheduler
    Log = ::Log.for("DELAYED_JOB_SCHEDULER")

    @loop = BackgroundLoop.new("delayed_job_scheduler")

    def initialize(@store : Store = RedisStore.instance)
    end

    def delay(job : Job, delay_time : Time::Span)
      delay_in_ms = delay_time.from_now.to_unix_ms
      @store.schedule(job, delay_in_ms)
    end

    # Start the scheduler to process due delayed jobs
    def start
      started = @loop.start do
        process_due_jobs
        1.second # Check every second for due jobs
      end
      Log.info &.emit("Delayed job scheduler started") if started
    end

    # Stop the scheduler and wait for its fiber to exit
    def stop
      Log.info &.emit("Delayed job scheduler stopped") if @loop.stop
    end

    # Process delayed jobs that are due for all configured queues
    private def process_due_jobs
      return unless @store.is_a?(RedisStore)

      redis_store = @store.as(RedisStore)

      # Process delayed jobs for all configured queues
      JoobQ.config.queues.each do |queue_name, _|
        begin
          due_jobs = redis_store.process_due_delayed_jobs(queue_name)

          if !due_jobs.empty?
            Log.debug &.emit("Processed due delayed jobs",
              queue: queue_name,
              count: due_jobs.size
            )
          end
        rescue ex
          Log.error &.emit("Error processing delayed jobs for queue",
            queue: queue_name,
            error: ex.message
          )
        end
      end
    end
  end
end
