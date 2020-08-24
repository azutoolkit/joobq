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
          redis.pipelined do |pipe|
            100.times do |_i|
              pipe.brpoplpush @name, Queues::Busy.to_s, 0
            end
          end.each do |job|
            next unless job
            stats.processing
            json = job.as(String)
            job = T.from_json json
            process job, json
          end
        end
      end
    end

    def process(job : T, json : String, start = Time.local)
      job.perform
      stats.success @name, latency(start)
    rescue e
      log job, "error"
      stats.error job.queue, latency(start)
      handle_failure job, e, start
    ensure
      log job, "success"
      if redis.lpush(Queues::Completed.to_s, json)
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

    private def handle_failure(job : T, e : Exception, start)
      job.failed_at = Time.local
      Failed.add job, e
      
      if job.retries > 0
        Retry.attempt job
      else
        DeadLetter.add job
      end
    end

    private def latency(start)
      (Time.local - start).milliseconds
    end

    private def log(job : T, status : String)
      Log.trace { "#{@name} (#{@wid}) #{status.upcase} Job: #{job.class.name} (#{job.jid})" }
    end
  end
end
