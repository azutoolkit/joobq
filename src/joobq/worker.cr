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
            process job if job
          end
        end
        @queue.terminate(worker: self)
      end
    rescue ex : Exception
      Log.error &.emit("Fetch Error", {worker_id: wid, reason: ex.message})
      @queue.restart self, ex
    end

    private def process(job : T, start = Time.monotonic)
      job.perform
    rescue ex
      record_failure job, ex, latency(start)
      handle_failure job
    ensure
      spawn do
        Log.info &.emit("Processed", {queue: name, worker_id: wid, job_id: job.jid.to_s})
      end
      Statistics.record_stats name, wid, "#{job.jid}", latency(start)
    end

    private def handle_failure(job : T)
      if job.retries > 0
        Retry.attempt job, @queue
      else
        DeadLetter.add job
      end
    end

    private def record_failure(job, ex, latency)
      redis.command ["TS.ADD", "stats:#{name}:error", "*", "#{latency}"]
      Failed.add job, ex
    end

    private def latency(start)
      (Time.monotonic - start).milliseconds
    end
  end
end
