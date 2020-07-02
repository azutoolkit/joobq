module JoobQ
  class Worker(T)
    Log = ::Log.for("WORKER")
    private getter redis : Redis::PooledClient = JoobQ.redis
    private getter stats : Statistics = JoobQ.statistics
    getter wid : Int32
    property? running : Bool = false

    @start : Time = Time.local
    @channel = Channel(T | Control).new(JoobQ.workers_capacity)
    @done = Channel(Control).new

    def initialize(@name : String, @wid : Int32)
    end

    def add(job : T)
      @channel.send job
    end

    def run
      return if running?
      @running = true
      spawn do
        loop do
          case job = @channel.receive
          when T
            start = Time.local
            begin
              job.perform
              stats_tick start
              complete(job)
              @running = false
              log(job, Queues::Completed)
            rescue e
              retry_attempt job, e
            ensure
              redis.lrem(Queues::Busy.to_s, 0, job.to_json)
            end
          when Control
            @done.send Control::Stop
            break
          end
        end
      end
    end

    def stop
      @channel.send Control::Stop
    end

    def join
      @done.receive
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
      Log.trace { "#{@name} (#{@wid}) Job ID: #{job.class.name} (#{job.jid}) - #{state} - Retries Left: #{job.retries}#{message}" }
    end

    private def stats_tick(start : Time)
      stats.track @name, @wid, (Time.local - start).microseconds
    end

    private def retry_attempt(job : T, e : Exception)
      job.failed_at = Time.local
      if job.retries > 0
        count = job.retries
        job.retries = job.retries - 1
        redis.zadd Sets::Retry.to_s, retry_at(count).to_unix_f, job.to_json
      else
        reap job
      end
    end

    private def retry_at(count : Int32)
      Time.local + ((count ** 4) + 15 + (rand(30)*(count + 1))).seconds
    end

    private def reap(job)
      dead_set = Sets::Dead.to_s
      now = Time.local.to_unix_f
      expires = (Time.local - 6.months).to_unix_f
      redis.zadd(dead_set, now, job.to_json)
      redis.zremrangebyscore(dead_set, "-inf", expires)
      redis.zremrangebyrank(dead_set, 0, -10_000)
    end
  end
end
