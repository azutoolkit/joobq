module JoobQ
  class RedisStore < Store
    private FAILED_SET       = "joobq:failed_jobs"
    private DEAD_LETTER      = "joobq:dead_letter"
    private DELAYED_SET      = "joobq:delayed_jobs"
    private PROCESSING_QUEUE = "joobq:processing"

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

    def get(queue : String, klass : Class) : Job?
      if job_data = redis.brpoplpush(queue, PROCESSING_QUEUE, 5)
        return klass.from_json(job_data.as(String))
      end
    end

    def put_back(queue : String) : String?
      redis.brpoplpush(PROCESSING_QUEUE, queue, 5)
    end

    def push(job) : String
      redis.rpush job.queue, job.to_json
      job.jid.to_s
    end

    def [](job_id : String | UUID) : String?
      redis.get("jobs:#{job_id}")
    end

    def delete(job)
      redis.rpop PROCESSING_QUEUE
    rescue ex
      # Log.error &.emit("Error deleting job", jid: job.jid, error: ex.message)
    end

    def failed(job, error) : Nil
      redis.set FAILED_SET, {job: job, error: error}.to_json
    end

    def dead(job, expires) : Nil
      redis.zadd DEAD_LETTER, Time.local.to_unix_f, job.to_s
    end

    def add_delayed(job : JoobQ::Job, delay_in_ms : Int64) : Nil
      future_timestamp = (Time.local.to_unix_ms + delay_in_ms)
      redis.zadd(DELAYED_SET, future_timestamp, job.to_json)
    end

    def get_delayed(now = Time.local) : Array(String)
      score = now.to_unix_ms + 1.minute.to_i
      # Fetch the first 50 jobs that are due for processing based on their scores
      jobs = redis.zrangebyscore(DELAYED_SET, "-inf", score, with_scores: false, limit: [0, 50])

      # Remove fetched jobs from the sorted set
      redis.zremrangebyscore(DELAYED_SET, "-inf", score)
      jobs.map &.as(String)
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
