module JoobQ
  class Worker(T)
    Log = ::Log.for("WORKER")

    getter wid : Int32
    property? active : Bool = false
    private getter redis : Redis::PooledClient = JoobQ::REDIS

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
            job = @queue.get_next
            execute job if job
          end
        end
      end
    rescue ex : Exception
      Log.error &.emit("Fetch", {worker_id: wid, reason: ex.message})
      @queue.restart self, ex
    end

    private def execute(job : T, start = Time.monotonic)
      job.perform
      Track.success job, start
    rescue ex : Exception
      Track.failure job, start, ex
    ensure
      Track.processed job, start
    end
  end
end
