module JoobQ
  class Worker(T)
    Log = ::Log.for("WORKER")
    private getter redis : Redis::PooledClient = JoobQ.redis
    private getter stats : Statistics = JoobQ.statistics
    getter wid : Int32
    property? running : Bool = false

    def initialize(@name : String, @wid : Int32)
      @stopped = true
    end

    def run
      return if running?
      @stopped = false

      spawn do
        loop do
          result = redis.pipelined do |pipe|
            100.times do |_i|
              pipe.brpoplpush @name, Queues::Busy.to_s, 0
            end
          end.each do |job|
            next unless job
            json = job.as(String)
            job = T.from_json json
            process job, json
         end
        end
      end
    end

    def process(job : T, json : String, start = Time.local)
      job.perform
      status = "complete"
    rescue e
      status = "error"
      handle_failure(job, e)
    ensure
      log job, status
      stats_tick start, status
      if redis.lpush(Queues::Completed.to_s,json)
        redis.lrem(Queues::Busy.to_s, 0, json)
      end
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

    private def stats_tick(start : Time, status)
      stats.track @name, @wid, (Time.local - start).microseconds, status
    end

    private def handle_failure(job : T, e : Exception)
      job.failed_at = Time.local
      error(e)
      Failed.add job, e
      
      if job.retries > 0
        Retry.attempt job
      else
        DeadLetter.add job
      end
    end

    private def log(job : T, status : String)
      Log.trace { "#{@name} (#{@wid}) Status: #{status} Job ID: #{job.class.name} (#{job.jid})" }
    end

    private def error(ex : Exception)
      error_msg = String.build do |io|
        io << "JoobQ error:\n"
        io << "#{ex.class} #{ex}\n"
        io << ex.backtrace.join("\n") if ex.backtrace
      end
      Log.error { error_msg }
    end
  end
end
