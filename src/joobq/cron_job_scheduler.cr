module JoobQ
  class CronJobScheduler
    private getter time_location = JoobQ.config.time_location

    getter jobs : Hash(String, Scheduler::CronJob)

    def initialize(@error_backoff : Time::Span = BackgroundLoop::ERROR_BACKOFF)
      @jobs = {} of String => Scheduler::CronJob
      @loops = [] of BackgroundLoop
    end

    def cron(pattern : String, timezone : Time::Location = time_location, &block : ->)
      job_key = "#{pattern}:#{timezone.name}"
      parser = CronParser.new(pattern)

      @jobs[job_key] = Scheduler::CronJob.new(
        pattern: pattern,
        timezone: timezone,
        next_run: parser.next(Time.local(timezone)).to_s,
        block: block
      )

      # One iteration either schedules the next run (and returns how long to
      # wait for it) or fires the run that is now due. If an iteration raises,
      # BackgroundLoop logs it (with the exception class), backs off and calls
      # the body again, so one bad iteration never ends the schedule.
      due = false
      prev_nxt = 1.minute.ago
      scheduler_loop = BackgroundLoop.new("cron:#{job_key}", @error_backoff)
      @loops << scheduler_loop

      scheduler_loop.start do
        if due
          due = false
          fire(block, pattern, timezone)
        end

        now = Time.local(timezone) # Adjust to the provided timezone
        nxt = parser.next(now)
        @jobs[job_key].next_run(nxt)

        # Avoid duplicate executions
        nxt = parser.next(nxt) if nxt <= prev_nxt
        prev_nxt = nxt

        due = true
        {nxt - now, Time::Span.zero}.max
      end
    end

    # Stops every cron loop. Returns once no loop will run another iteration.
    def stop : Nil
      @loops.each(&.stop)
    end

    private def fire(block : ->, pattern : String, timezone : Time::Location) : Nil
      spawn do
        begin
          block.call
        rescue ex : Exception
          Log.error &.emit("Cron job execution failed",
            pattern: pattern, timezone: timezone.name,
            error_class: ex.class.name, reason: ex.message)
        end
      end
    end
  end
end
