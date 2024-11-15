module JoobQ
  class Worker(T)
    Log = ::Log.for("WORKER")

    getter wid : Int32
    property? active : Bool = false

    @last_job_time : Int64

    def initialize(@wid : Int32, @terminate : Channel(Nil), @queue : Queue(T))
      @last_job_time = Time.utc.to_unix_ms
    end

    def name
      @queue.name
    end

    def stop!
      @terminate.send nil
    end

    def run
      return if active?
      @active = true
      spawn do
        begin
          loop do
            select
            when @terminate.receive?
              @active = false
              break
            else
              if job = @queue.next_job
                job.running!

                if job.expires && Time.utc.to_unix_ms > job.expires
                  job.expired!
                  DeadLetterManager.add(job)
                  next
                end

                throttle if @queue.throttle_limit
                @queue.busy.add(1)
                execute job
                @queue.busy.sub(1)
              end
            end
          end
        rescue ex : Exception
          Log.error &.emit("Fetch", worker_id: wid, reason: ex.message)
          @queue.restart self, ex
        end
      end
    end

    private def throttle
      if throttle_limit = @queue.throttle_limit
        min_interval = (1000.0 / throttle_limit) # milliseconds
        now = Time.utc.to_unix_ms
        elapsed = now - @last_job_time
        sleep_time = min_interval - elapsed
        if sleep_time > 0
          sleep (sleep_time / 1000.0).seconds
          @last_job_time = Time.utc.to_unix_ms
        else
          @last_job_time = now
        end
      end
    end

    private def execute(job : T)
      start = Time.monotonic
      job.perform
      job.completed!
      @queue.completed.add(1)
      @queue.store.delete job
    rescue ex : Exception
      FailHandler.call job, start, ex, @queue
    end
  end
end
