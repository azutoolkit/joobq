module JoobQ
  class Worker(T)
    Log = ::Log.for("WORKER")

    getter wid : Int32
    property? active : Bool = false

    def initialize(@wid : Int32, @terminate : Channel(Nil), @queue : Queue(T))
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
        loop do
          select
          when @terminate.receive?
            @active = false
            break
          else
            if @queue.throttle_limit
              now = Time.local.to_unix_ms
              if last_job_time = @queue.last_job_time
                elapsed = now - last_job_time
                sleep_time = (1000.0 / @queue.throttle_limit.not_nil!) - elapsed
                sleep sleep_time / 1000.0 if sleep_time > 0
              end
              @queue.last_job_time = now
            end
            job = @queue.next
            if job
              @queue.busy.add(1)
              execute job
              @queue.busy.sub(1)
            end
          end
        end
      end
    rescue ex : Exception
      Log.error &.emit("Fetch", worker_id: wid, reason: ex.message)
      @queue.restart self, ex
    end

    private def execute(job : T, start = Time.monotonic)
      job.running!
      job.perform
      job.completed!
      @queue.completed.add(1)
      @queue.store.delete job
    rescue ex : Exception
      FailHandler.call job, start, ex, @queue
    end
  end
end
