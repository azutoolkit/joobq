module JoobQ
  class DelayedJobScheduler
    Log = ::Log.for("DELAYED_JOB_SCHEDULER")

    @running = Atomic(Bool).new(false)
    @scheduler_fiber : Fiber?

    def initialize(@store : Store = RedisStore.instance)
    end

    def delay(job : Job, delay_time : Time::Span)
      delay_in_ms = delay_time.from_now.to_unix_ms
      @store.schedule(job, delay_in_ms)
    end

    # Start the scheduler to process due delayed jobs
    def start
      return if @running.get
      @running.set(true)

      @scheduler_fiber = spawn do
        Log.info &.emit("Delayed job scheduler started")

        while @running.get
          begin
            process_due_jobs
            sleep 1.second # Check every second for due jobs
          rescue ex
            Log.error &.emit("Delayed job scheduler error", error: ex.message)
            sleep 5.seconds # Back off on error
          end
        end
      end
    end

    # Stop the scheduler
    def stop
      return unless @running.get
      @running.set(false)
      # Give the fiber time to finish its current iteration
      sleep 0.1.seconds
      Log.info &.emit("Delayed job scheduler stopped")
    end

    # Process delayed jobs that are due for all configured queues
    private def process_due_jobs
      return unless @store.is_a?(RedisStore)

      redis_store = @store.as(RedisStore)

      # Process delayed jobs for all configured queues
      JoobQ.config.queues.each do |queue_name, queue_config|
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
