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
      Log.info &.emit("Job completed", queue: job.queue, jid: job.jid.to_s)
      @queue.completed.add(1)
      @queue.store.delete job
    rescue ex : Exception
      FailHandler.call job, start, ex, @queue
    end
  end
end
