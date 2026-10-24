module JoobQ
  class RecurringJobScheduler
    getter jobs : Hash(String, Scheduler::RecurringJob)

    def self.instance
      @@instance ||= new
    end

    def initialize(@error_backoff : Time::Span = BackgroundLoop::ERROR_BACKOFF)
      @jobs = {} of String => Scheduler::RecurringJob
      @loops = [] of BackgroundLoop
    end

    def every(interval : Time::Span, job : Job.class, **args)
      job_instance = job.new(**args)
      job_key = job_instance.class.name
      @jobs[job_key] = Scheduler::RecurringJob.new(interval: interval, job: job.name, args: args.to_json)

      scheduler_loop = BackgroundLoop.new("recurring:#{job_key}", @error_backoff)
      @loops << scheduler_loop

      scheduler_loop.start do
        spawn do
          begin
            job_instance.perform
          rescue ex : Exception
            Log.error &.emit("Recurring job execution failed",
              job: job_key, error_class: ex.class.name, error: ex.message)
          end
        end
        interval
      end

      job_instance
    end

    # Stops every recurring loop. Returns once no loop will run another iteration.
    def stop : Nil
      @loops.each(&.stop)
    end
  end
end
