module JoobQ
  class Worker(T)
    Log = ::Log.for("WORKER")
    private getter redis : Redis::PooledClient = JoobQ.redis
    private getter stats : Statistics = JoobQ.statistics
    getter wid : Int32
    property? running : Bool = false

    @start : Time = Time.local

    def initialize(@name : String, @wid : Int32, @job_queue : Channel(Array(String)))
      @stopped = true
    end

    def run
      return if running?
      @stopped = false

      spawn do
        loop do
          jobs = @job_queue.receive
          jobs.each do |job|
            next unless job
            process T.from_json(job.as(String))
          end
        end
      end
    end

    def process(job : T)
      start = Time.local
      job.perform
      stats_tick start
      complete(job)
      log(job, Queues::Completed)
    rescue e
      handle_failure(job, e)
    ensure
      redis.lrem(Queues::Busy.to_s, 0, job.to_json)
    end

    def stop
      @stopped = true
    end

    def stopped?
      @stopped
    end

    def running?
      !@stopped
    end

    private def complete(job)
      if redis.lpush(Queues::Completed.to_s, job.to_json)
        redis.lrem(Queues::Busy.to_s, 0, job.to_json)
      end
    end

    private def log_err(ex : Exception)
      error_msg = String.build do |io|
        io << "JoobQ error:\n"
        io << "#{ex.class} #{ex}\n"
        io << ex.backtrace.join("\n") if ex.backtrace
      end
      Log.error { error_msg }
    end

    private def log(job : T, state : JoobQ::Queues, message = "")
      Log.trace { "#{@name} (#{@wid}) Job ID: #{job.class.name} (#{job.jid})" }
    end

    private def stats_tick(start : Time)
      stats.track @name, @wid, (Time.local - start).microseconds
    end

    private def handle_failure(job : T, e : Exception)
      job.failed_at = Time.local

      Failed.add job, e

      if job.retries > 0
        Retry.attempt job
      else
        DeadLetter.add job
      end
    end
  end
end
