module JoobQ
  class CronJobScheduler
    private getter time_location = JoobQ.config.time_location

    getter jobs : Hash(String, Scheduler::CronJob)

    def initialize
      @jobs = {} of String => Scheduler::CronJob
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

      spawn do
        prev_nxt = 1.minute.ago
        loop do
          now = Time.local(timezone) # Adjust to the provided timezone
          nxt = parser.next(now)
          @jobs[job_key].next_run(nxt)

          # Avoid duplicate executions
          nxt = parser.next(nxt) if nxt <= prev_nxt
          prev_nxt = nxt

          sleep_duration = (nxt - now)
          if sleep_duration.seconds > 0
            sleep(sleep_duration.seconds)
          end

          # Execute the job
          begin
            spawn { block.call }
          rescue ex : Exception
            Log.error &.emit("Cron job execution failed", pattern: pattern, timezone: timezone.name, reason: ex.message)
          end
        end
      end
    end
  end
end
