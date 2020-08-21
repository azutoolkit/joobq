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
      complete job, start
    rescue e
      handle_failure job, e, start
    ensure
      cleanup json
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

    def complete(job, start)
      log job, "complete"
      stats_tick start,  "complete"
    end

    private def cleanup(json : String)
      if redis.lpush(Queues::Completed.to_s, json)
        redis.lrem(Queues::Busy.to_s, 0, json)
      end
    end

    private def stats_tick(start : Time, status : String)
      stats.track @name, @wid, (Time.local - start).microseconds, status
    end

    private def handle_failure(job : T, e : Exception, start)
      job.failed_at = Time.local
      error(job, e)
      stats_tick start, "error"
      Failed.add job, e
      
      if job.retries > 0
        Retry.attempt job
      else
        DeadLetter.add job
      end
    end

    private def log(job : T, status : String)
      Log.trace { "#{@name} (#{@wid}) #{status.upcase} Job: #{job.class.name} (#{job.jid})" }
    end

    private def error(job : T, ex : Exception)
      error_msg = String.build do |io|
        io << "JOB error:\n"
        io << "JOB ID: #{job.jid}\n"
        io << "#{ex.class} #{ex}\n"
        io << ex.backtrace.join("\n") if ex.backtrace
      end
      Log.error { error_msg }
    end
  end
end
