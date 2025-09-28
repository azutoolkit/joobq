module JoobQ
  class RedisStore < Store
    FAILED_SET       = "joobq:failed_jobs"
    DELAYED_SET      = "joobq:delayed_jobs"
    private DEAD_LETTER      = "joobq:dead_letter"
    private PROCESSING_QUEUE = "joobq:processing"
    private BLOCKING_TIMEOUT = 5

    # Cached Lua script SHA for better performance
    @@claim_job_script_sha : String? = nil
    @@claim_jobs_batch_script_sha : String? = nil
    @@release_claims_batch_script_sha : String? = nil

    def self.instance : RedisStore
      @@instance ||= new
    end

    getter redis : Redis::PooledClient

    def initialize(@host : String = ENV.fetch("REDIS_HOST", "localhost"),
                   @port : Int32 = ENV.fetch("REDIS_PORT", "6379").to_i,
                   @password : String? = ENV["REDIS_PASS"]?,
                   @pool_size : Int32 = ENV.fetch("REDIS_POOL_SIZE", "500").to_i,
                   @pool_timeout : Float64 = ENV.fetch("REDIS_POOL_TIMEOUT", "5.0").to_f)
      @redis = Redis::PooledClient.new(
        host: @host,
        port: @port,
        password: @password,
        pool_size: @pool_size,
        pool_timeout: @pool_timeout
      )

      # Cache Lua scripts for better performance
      cache_lua_scripts

      # Initialize connection health monitoring
      start_connection_health_monitor

      # Pre-warm connections for better performance
      pre_warm_connections
    end

    # Cache Lua scripts to avoid recompilation overhead
    private def cache_lua_scripts
      begin
        # Cache claim_jobs_batch script
        @@claim_jobs_batch_script_sha = redis.script_load(claim_jobs_batch_lua_script)

        # Cache release_claims_batch script
        @@release_claims_batch_script_sha = redis.script_load(release_claims_batch_lua_script)

        Log.debug &.emit("Lua scripts cached successfully")
      rescue ex
        Log.warn &.emit("Failed to cache Lua scripts", error: ex.message)
        # Fall back to EVAL if caching fails
        @@claim_jobs_batch_script_sha = nil
        @@release_claims_batch_script_sha = nil
      end
    end

    # Get the Lua script for claim_jobs_batch
    private def claim_jobs_batch_lua_script : String
      <<-LUA
        local queue_key = KEYS[1]
        local processing_key = KEYS[2]
        local worker_claim_key = KEYS[3]
        local worker_id = ARGV[1]
        local batch_size = tonumber(ARGV[2])
        local timeout = tonumber(ARGV[3])

        -- Pre-allocate arrays for better performance
        local jobs = {}
        local claim_keys = {}
        local claim_data = {}

        -- Get current time once
        local current_time = redis.call('TIME')[1]

        -- Claim multiple jobs in a single loop with optimized operations
        for i = 1, batch_size do
          local job_data = redis.call('RPOPLPUSH', queue_key, processing_key)
          if job_data then
            jobs[i] = job_data
            -- Pre-build claim key and data for batch operations
            local job_claim_key = worker_claim_key .. ':' .. i
            claim_keys[i] = job_claim_key
            claim_data[i] = {job_data, current_time}
          else
            break -- No more jobs available
          end
        end

        -- Batch create claim records using MSET for better performance
        if #jobs > 0 then
          local claim_args = {}
          for i = 1, #jobs do
            local job_claim_key = claim_keys[i]
            claim_args[#claim_args + 1] = job_claim_key .. ':job'
            claim_args[#claim_args + 1] = claim_data[i][1]
            claim_args[#claim_args + 1] = job_claim_key .. ':claimed_at'
            claim_args[#claim_args + 1] = claim_data[i][2]
          end

          -- Use MSET for batch setting
          if #claim_args > 0 then
            redis.call('MSET', unpack(claim_args))

            -- Batch set expiration for all claim keys
            for i = 1, #jobs do
              redis.call('EXPIRE', claim_keys[i], 3600)
            end
          end
        end

        return jobs
      LUA
    end

    # Get the Lua script for release_claims_batch
    private def release_claims_batch_lua_script : String
      <<-LUA
        local worker_claim_key = KEYS[1]
        local job_count = tonumber(ARGV[1])

        local keys_to_delete = {}
        for i = 1, job_count do
          keys_to_delete[#keys_to_delete + 1] = worker_claim_key .. ':' .. i
        end

        if #keys_to_delete > 0 then
          redis.call('DEL', unpack(keys_to_delete))
        end
      LUA
    end

    def reset : Nil
      redis.flushdb
    end

    def clear_queue(queue_name : String) : Nil
      redis.del(queue_name)
    end

    def delete_job(job : String) : Nil
      job_data = JSON.parse(job)
      queue_name = job_data["queue"].as_s
      processing_key = processing_queue(queue_name)

      # Remove the specific job from the processing queue
      redis.lrem(processing_key, 1, job)
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
      if job_data = redis.rpoplpush(queue_name, processing_queue(queue_name))
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
        local job_data = redis.call('RPOPLPUSH', queue_key, processing_key)
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

    # Batch job claiming for improved performance
    def claim_jobs_batch(queue_name : String, worker_id : String, klass : Class, batch_size : Int32 = 5) : Array(String)
      processing_key = processing_queue(queue_name)
      worker_claim_key = "#{processing_key}:#{worker_id}"

      # Use cached script if available, otherwise fall back to EVAL
      result = if script_sha = @@claim_jobs_batch_script_sha
        begin
          redis.evalsha(script_sha, [queue_name, processing_key, worker_claim_key],
                       [worker_id, batch_size.to_s, BLOCKING_TIMEOUT])
        rescue
          # Script not found, fall back to EVAL and recache
          cache_lua_scripts
          redis.eval(claim_jobs_batch_lua_script, [queue_name, processing_key, worker_claim_key],
                    [worker_id, batch_size.to_s, BLOCKING_TIMEOUT])
        end
      else
        redis.eval(claim_jobs_batch_lua_script, [queue_name, processing_key, worker_claim_key],
                  [worker_id, batch_size.to_s, BLOCKING_TIMEOUT])
      end

      if result && result.as(Array).any?
        result.as(Array).map(&.as(String))
      else
        [] of String
      end
    rescue ex
      Log.error &.emit("Error claiming jobs batch", queue: queue_name, worker: worker_id,
                      batch_size: batch_size, error: ex.message)
      [] of String
    end

    def release_job_claim(queue_name : String, worker_id : String) : Nil
      processing_key = processing_queue(queue_name)
      worker_claim_key = "#{processing_key}:#{worker_id}"

      # Remove the worker's claim
      redis.del(worker_claim_key)
    rescue ex
      Log.error &.emit("Error releasing job claim", queue: queue_name, worker: worker_id, error: ex.message)
    end

    # Batch release job claims for improved performance
    def release_job_claims_batch(queue_name : String, worker_id : String, job_count : Int32) : Nil
      processing_key = processing_queue(queue_name)
      worker_claim_key = "#{processing_key}:#{worker_id}"

      # Use cached script if available, otherwise fall back to EVAL
      if script_sha = @@release_claims_batch_script_sha
        begin
          redis.evalsha(script_sha, [worker_claim_key], [job_count.to_s])
        rescue
          # Script not found, fall back to EVAL and recache
          cache_lua_scripts
          redis.eval(release_claims_batch_lua_script, [worker_claim_key], [job_count.to_s])
        end
      else
        redis.eval(release_claims_batch_lua_script, [worker_claim_key], [job_count.to_s])
      end
    rescue ex
      Log.error &.emit("Error releasing job claims batch", queue: queue_name, worker: worker_id,
                      job_count: job_count, error: ex.message)
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

    # Start background fiber for connection health monitoring
    private def start_connection_health_monitor
      spawn do
        loop do
          sleep 30.0 # Check every 30 seconds
          validate_pool_connections
        rescue ex
          Log.error &.emit("Connection health monitor error", error: ex.message)
        end
      end
    end

    # Validate all connections in the pool and remove stale ones
    private def validate_pool_connections
      begin
        # Test a simple ping to validate connection health
        redis.ping
        Log.debug &.emit("Redis pool health check passed",
                        pool_size: @pool_size,
                        pool_timeout: @pool_timeout)
      rescue ex
        Log.warn &.emit("Redis pool health check failed", error: ex.message)
        # In a production environment, you might want to implement
        # connection pool recreation or more sophisticated recovery
      end
    end

    # Get pool statistics for monitoring
    def pool_stats : Hash(String, Int32)
      {
        "pool_size" => @pool_size,
        "pool_timeout" => @pool_timeout.to_i,
        "available_connections" => redis.pool.pending,
        "total_connections" => redis.pool.size
      }
    end

    # Pre-warm connections to reduce latency during high load
    private def pre_warm_connections
      spawn do
        begin
          # Pre-warm a subset of connections (10% of pool size, max 50)
          connections_to_warm = Math.min(@pool_size // 10, 50)

          connections_to_warm.times do |i|
            spawn do
              begin
                redis.ping
                Log.debug &.emit("Pre-warmed Redis connection", connection: i + 1)
              rescue ex
                Log.warn &.emit("Failed to pre-warm connection", connection: i + 1, error: ex.message)
              end
            end
          end

          Log.info &.emit("Pre-warming #{connections_to_warm} Redis connections")
        rescue ex
          Log.warn &.emit("Error during connection pre-warming", error: ex.message)
        end
      end
    end

    # Force pool recreation if needed (for recovery scenarios)
    def recreate_pool : Nil
      Log.info &.emit("Recreating Redis connection pool")
      @redis = Redis::PooledClient.new(
        host: @host,
        port: @port,
        password: @password,
        pool_size: @pool_size,
        pool_timeout: @pool_timeout
      )
      cache_lua_scripts
      pre_warm_connections
    end

  end
end
