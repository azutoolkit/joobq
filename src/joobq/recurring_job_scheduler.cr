module JoobQ
  class RecurringJobScheduler
    getter jobs : Hash(String, Scheduler::RecurringJob)

    @@instance_lock = Sync::Mutex.new

    def self.instance
      @@instance_lock.synchronize { @@instance ||= new }
    end

    def initialize(@error_backoff : Time::Span = BackgroundLoop::ERROR_BACKOFF)
      @jobs = {} of String => Scheduler::RecurringJob
      @loops = [] of BackgroundLoop
      @lock = Sync::Mutex.new
    end

    def every(interval : Time::Span, job : Job.class, **args)
      job_instance = job.new(**args)
      every(interval, job.name, job.name, args.to_json) { job_instance.perform }
      job_instance
    end

    # Runs `action` in a fiber every `interval`, the first time at once. `key` names the loop in `jobs`, next to
    # the `job` name and its `args` (JSON).
    def every(interval : Time::Span, key : String, job : String, args : String, &action : ->)
      @lock.synchronize do
        @jobs[key] = Scheduler::RecurringJob.new(interval: interval, job: job, args: args)
      end

      scheduler_loop = BackgroundLoop.new("recurring:#{key}", @error_backoff)
      @lock.synchronize { @loops << scheduler_loop }

      scheduler_loop.start do
        spawn do
          begin
            action.call
          rescue ex : Exception
            Log.error &.emit("Recurring job execution failed",
              job: key, error_class: ex.class.name, error: ex.message)
          end
        end
        interval
      end
    end

    # Stops every recurring loop. Returns once no loop will run another iteration.
    def stop : Nil
      loops = @lock.synchronize { @loops.dup }
      loops.each(&.stop)
    end
  end
end
