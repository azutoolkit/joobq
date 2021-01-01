module JoobQ
  class Worker(T)
    Log = ::Log.for("WORKER")

    getter wid : Int32
    property? running : Bool = false

    private getter redis : Redis::PooledClient = JoobQ.redis
    private getter stats : Statistics = JoobQ.statistics

    def initialize(@wid : Int32, @terminate : Channel(Nil), @queue : Queue(T))
    end

    def name
      @queue.name
    end

    def run
      spawn do
        loop do
          select
          when @terminate.receive?
            break
          else
            job = @queue.get_next
            execute job if job
          end
        end
        @queue.terminate(worker: self)
      end
    rescue ex : Exception
      Log.error &.emit("Fetch Error", {worker_id: wid, reason: ex.message})
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
