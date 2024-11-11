module JoobQ
  class RedisStore < Store
    private FAILED_SET  = Sets::Failed.to_s
    private DEAD_LETTER = Sets::Dead.to_s

    @@expiration = JoobQ.config.expires
    getter redis : Redis::PooledClient

    def initialize(@host : String = ENV.fetch("REDIS_HOST", "localhost"),
                   @port : Int32 = ENV.fetch("REDIS_PORT", "6379").to_i,
                   @password : String? = ENV["REDIS_PASS"]?,
                   @pool_size : Int32 = ENV.fetch("REDIS_POOL_SIZE", "100").to_i,
                   @pool_timeout : Time::Span = 0.5.seconds)
      @redis = Redis::PooledClient.new(
        host: @host,
        port: @port,
        password: @password,
        pool_size: @pool_size,
        pool_timeout: 1.seconds
      )
    end

    def reset : Nil
      redis.flushdb
    end

    def get(queue : String, target_queue : String, klass : Class) : Job?
      if job_data = redis.brpoplpush(queue, target_queue, 0.2)
        return klass.from_json(job_data.as(String))
      end
    end

    def push(job) : String
      redis.rpush job.queue, job.to_json
      job.jid.to_s
    end

    def [](job_id : String | UUID) : String?
      redis.get("jobs:#{job_id}")
    end

    def delete(job)
      redis.rpop Status::Busy.to_s
    rescue ex
      # Log.error &.emit("Error deleting job", jid: job.jid, error: ex.message)
    end

    def failed(job, error) : Nil
      redis.set "failed:#{job.jid}", {job: job, error: error}.to_json
    end

    def dead(job, expires) : Nil
      redis.pipelined do |piped|
        piped.zadd DEAD_LETTER, Time.local.to_unix_f, job.jid.to_s
        piped.zremrangebyscore DEAD_LETTER, "-inf", expires
        piped.zremrangebyrank DEAD_LETTER, 0, -10_000
      end
    end

    def add_delayed(job : JoobQ::Job, till : Time::Span) : Nil
      redis.zadd(Sets::Delayed.to_s, till.from_now.to_unix_f, job.to_json)
    end

    def get_delayed(now = Time.local) : Array(String)
      moment = "%.6f" % now.to_unix_f
      redis.zrangebyscore(Sets::Delayed.to_s, "-inf", moment, limit: [0, 10]).map do |job|
        job.as(String)
      end
    end

    def remove_delayed(job) : Int64
      redis.zrem(Sets::Delayed.to_s, job.to_json)
    end

    def length(queue : String) : Int64
      redis.llen(queue)
    end

    def list(queue : String, page_number : Int32 = 1, page_size : Int32 = 200) : Array(Job)
      start_index = (page_number - 1) * page_size
      end_index = start_index + page_size - 1
      redis.lrange(queue, start_index, end_index)
    end
  end
end
