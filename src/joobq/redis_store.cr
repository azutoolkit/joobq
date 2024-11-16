module JoobQ
  class RedisStore < Store
    private FAILED_SET       = "joobq:failed_jobs"
    private DEAD_LETTER      = "joobq:dead_letter"
    private DELAYED_SET      = "joobq:delayed_jobs"
    private PROCESSING_QUEUE = "joobq:processing"
    private BLOCKING_TIMEOUT = 5

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
        pool_timeout: @pool_timeout
      )
    end

    def reset : Nil
      redis.flushdb
    end

    def clear_queue(queue_name : String) : Nil
      redis.del(queue_name)
    end

    def delete_job(job : JoobQ::Job) : Nil
      redis.rpop PROCESSING_QUEUE
    end

    def enqueue(job : JoobQ::Job) : String
      redis.rpush job.queue, job.to_json
      job.jid.to_s
    end

    def dequeue(queue_name : String, klass : Class) : JoobQ::Job?
      if job_data = redis.brpoplpush(queue_name, PROCESSING_QUEUE, BLOCKING_TIMEOUT)
        return klass.from_json(job_data.as(String))
      end
    end

    def move_job_back_to_queue(queue_name : String) : Bool
      redis.brpoplpush(PROCESSING_QUEUE, queue_name, BLOCKING_TIMEOUT)
      true
    rescue
      false
    end

    def mark_as_failed(job : JoobQ::Job, error_details : Hash) : Nil
      redis.set FAILED_SET, {job: job, error: error_details}.to_json
    end

    def mark_as_dead(job : JoobQ::Job, expiration_time : String) : Nil
      redis.zadd DEAD_LETTER, expiration_time, job.to_json
    end

    def schedule(job : JoobQ::Job, delay_in_ms : Int64) : Nil
      redis.zadd DELAYED_SET, delay_in_ms, job.to_json
    end

    def fetch_due_jobs(current_time = Time.local) : Array(String)
      score = current_time.to_unix_ms
      jobs = redis.zrangebyscore(DELAYED_SET, 0, score, with_scores: false, limit: [0, 50])
      puts "Fetched #{jobs.size} jobs from delayed set current time #{current_time}"
      redis.zremrangebyscore(DELAYED_SET, "-inf", score)
      jobs.map &.as(String)
    end

    def queue_size(queue_name : String) : Int64
      redis.llen(queue_name)
    end

    def set_size(set_name : String) : Int64
      redis.zcard(set_name)
    end

    def list_jobs(queue_name : String, page_number : Int32 = 1, page_size : Int32 = 200) : Array(String)
      start_index = (page_number - 1) * page_size
      end_index = start_index + page_size - 1
      redis.lrange(queue_name, start_index, end_index).map &.as(String)
    end
  end
end
