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
      record_success name, job.jid, start
    rescue ex
      record_failure start
      handle_failure job, ex
    ensure
      log_processed job.jid
    end
    
    private def record_success(name, jid, start)
      Statistics.record_success name, "#{jid}", latency(start)
    end

    private def record_failure(start)
      Statistics.record_failure name, latency(start)
    end

    private def handle_failure(job : T, ex : Exception)
      Failed.add job, ex
      if job.retries > 0
        Retry.attempt job, @queue
      else
        DeadLetter.add job
      end
    end

    private def log_processed(jid)
      spawn do
        Log.info &.emit("Processed", {queue: name, worker_id: wid, job_id: jid.to_s})
      end
    end

    private def latency(start)
      (Time.monotonic - start).milliseconds
    end
  end
end
