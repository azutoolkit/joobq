module JoobQ
  class RedisStore < Store
    FAILED_SET       = "joobq:failed_jobs"
    DELAYED_SET      = "joobq:delayed_jobs"
    private DEAD_LETTER      = "joobq:dead_letter"
    private PROCESSING_QUEUE = "joobq:processing"
    private BLOCKING_TIMEOUT = 5

    def self.instance : RedisStore
      @@instance ||= new
    end

    getter redis : Redis::PooledClient

    def initialize(@host : String = ENV.fetch("REDIS_HOST", "localhost"),
                   @port : Int32 = ENV.fetch("REDIS_PORT", "6379").to_i,
                   @password : String? = ENV["REDIS_PASS"]?,
                   @pool_size : Int32 = ENV.fetch("REDIS_POOL_SIZE", "100").to_i,
                   @pool_timeout : Float64 = 0.5)
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

    def delete_job(job : String) : Nil
      job = JSON.parse(job)
      redis.lpop processing_queue(job["queue"].as_s)
    end

    def enqueue(job : Job) : String
      redis.rpush job.queue, job.to_json
      job.jid.to_s
    end

    def enqueue_batch(jobs : Array(Job), batch_size : Int32 = 1000) : Nil
      raise "Batch size must be greater than 0" if batch_size <= 0
      raise "Batch size must be less than or equal to 1000" if batch_size > 1000

      jobs.each_slice(batch_size) do |batch_jobs|
        redis.pipelined do |pipe|
          batch_jobs.each do |job|
            pipe.rpush job.queue, job.to_json
          end
        end
      end
    end

    def dequeue(queue_name : String, klass : Class) : String?
      if job_data = redis.brpoplpush(queue_name, processing_queue(queue_name), BLOCKING_TIMEOUT)
        return job_data.to_s
      end
      nil
    end

    # Atomic job claiming with worker identification
    def claim_job(queue_name : String, worker_id : String, klass : Class) : String?
      processing_key = processing_queue(queue_name)
      worker_claim_key = "#{processing_key}:#{worker_id}"

      # Use a Lua script for atomic job claiming
      lua_script = <<-LUA
        local queue_key = KEYS[1]
        local processing_key = KEYS[2]
        local worker_claim_key = KEYS[3]
        local worker_id = ARGV[1]
        local timeout = ARGV[2]

        -- Try to get a job from the queue
        local job_data = redis.call('BRPOPLPUSH', queue_key, processing_key, timeout)
        if job_data then
          -- Atomically claim the job for this worker
          redis.call('HSET', worker_claim_key, 'job', job_data)
          redis.call('HSET', worker_claim_key, 'claimed_at', redis.call('TIME')[1])
          redis.call('EXPIRE', worker_claim_key, 3600) -- 1 hour timeout
          return job_data
        end
        return nil
      LUA

      result = redis.eval(lua_script, [queue_name, processing_key, worker_claim_key], [worker_id, BLOCKING_TIMEOUT])
      result ? result.to_s : nil
    rescue ex
      Log.error &.emit("Error claiming job", queue: queue_name, worker: worker_id, error: ex.message)
      nil
    end

    def release_job_claim(queue_name : String, worker_id : String) : Nil
      processing_key = processing_queue(queue_name)
      worker_claim_key = "#{processing_key}:#{worker_id}"

      # Remove the worker's claim
      redis.del(worker_claim_key)
    rescue ex
      Log.error &.emit("Error releasing job claim", queue: queue_name, worker: worker_id, error: ex.message)
    end

    def move_job_back_to_queue(queue_name : String) : Bool
      redis.brpoplpush(processing_queue(queue_name), queue_name, BLOCKING_TIMEOUT)
      true
    rescue
      false
    end

    def mark_as_dead(job : Job, expiration_time : Int64) : Nil
      redis.zadd DEAD_LETTER, expiration_time, job.to_json
    end

    def schedule(job : Job, delay_in_ms : Int64, delay_set : String = DELAYED_SET) : Nil
      redis.zadd delay_set, delay_in_ms, job.to_json
    end

    def fetch_due_jobs(
      current_time = Time.local,
      delay_set : String = DELAYED_SET,
      limit : Int32 = 50,
      remove : Bool = true
    ) : Array(String)
      score = current_time.to_unix_ms
      jobs = redis.zrangebyscore(delay_set, 0, score, with_scores: false, limit: [0, limit])
      redis.zremrangebyscore(delay_set, "-inf", score) if remove
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

    def processing_list(pattern : String = "#{PROCESSING_QUEUE}:*", limit : Int32 = 100) : Array(String)
      jobs_collected = [] of String

      # Step 2: Collect jobs from each queue until the limit is reached
      JoobQ.queues.each do |key, _|
        break if jobs_collected.size >= limit # Stop if we've collected enough jobs
        # Calculate remaining jobs to fetch
        remaining = limit - jobs_collected.size
        # Fetch jobs from the current queue
        queue_jobs = redis.lrange(key, 0, remaining - 1)
        jobs_collected.concat(queue_jobs.map &.as(String))
      end

      jobs_collected
    end

    private def processing_queue(name : String)
      "#{PROCESSING_QUEUE}:#{name}"
    end
  end
end
