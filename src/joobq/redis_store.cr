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
                   @pool_size : Int32 = ENV.fetch("REDIS_POOL_SIZE", "100").to_i,
                   @pool_timeout : Float64 = 0.5)
      @redis = Redis::PooledClient.new(
        host: @host,
        port: @port,
        password: @password,
        pool_size: @pool_size,
        pool_timeout: @pool_timeout
      )

      # Cache Lua scripts for better performance
      cache_lua_scripts
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

    # Batch job cleanup with pipelining for improved performance
    def cleanup_jobs_batch_pipelined(worker_id : String, job_ids : Array(String), queue_name : String) : Nil
      return if job_ids.empty?

      processing_key = processing_queue(queue_name)
      worker_claim_key = "#{processing_key}:#{worker_id}"

      redis.pipelined do |pipe|
        # Release all job claims
        job_ids.each_with_index do |_, index|
          pipe.del("#{worker_claim_key}:#{index + 1}")
        end

        # Remove jobs from processing queue
        job_ids.each do |job_id|
          pipe.lrem(processing_key, 1, job_id)
        end

        # Update processing statistics
        pipe.hincrby("joobq:stats:processed", queue_name, job_ids.size)
        pipe.hincrby("joobq:stats:total_processed", "global", job_ids.size)
      end
    rescue ex
      Log.error &.emit("Error in batch job cleanup", queue: queue_name, worker: worker_id,
                      job_count: job_ids.size, error: ex.message)
    end

    # Enhanced job processing cleanup with pipelining
    def cleanup_job_processing_pipelined(worker_id : String, job_id : String, queue_name : String) : Nil
      processing_key = processing_queue(queue_name)
      worker_claim_key = "#{processing_key}:#{worker_id}"

      redis.pipelined do |pipe|
        pipe.del(worker_claim_key)                    # Release claim
        pipe.lrem(processing_key, 1, job_id)          # Remove from processing
        pipe.hincrby("joobq:stats:processed", queue_name, 1)  # Update stats
      end
    rescue ex
      Log.error &.emit("Error in pipelined job cleanup", queue: queue_name, worker: worker_id,
                      job_id: job_id, error: ex.message)
    end

    def list_jobs(queue_name : String, page_number : Int32 = 1, page_size : Int32 = 200) : Array(String)
      start_index = (page_number - 1) * page_size
      end_index = start_index + page_size - 1
      redis.lrange(queue_name, start_index, end_index).map &.as(String)
    end

    # Queue metrics structure for batch collection
    struct QueueMetrics
      include JSON::Serializable
      getter queue_size : Int64
      getter processing_size : Int64
      getter failed_count : Int64
      getter dead_letter_count : Int64
      getter processed_count : Int64

      def initialize(@queue_size : Int64, @processing_size : Int64,
                     @failed_count : Int64, @dead_letter_count : Int64,
                     @processed_count : Int64)
      end
    end

    # Get queue metrics for multiple queues using pipelining
    def get_queue_metrics_pipelined(queue_names : Array(String)) : Hash(String, QueueMetrics)
      metrics = {} of String => QueueMetrics

      if queue_names.empty?
        return metrics
      end

      # Process results (Redis pipelined returns results in order)
      results = redis.pipelined do |pipe|
        queue_names.each do |queue_name|
          pipe.llen(queue_name)                                    # Queue size
          pipe.llen(processing_queue(queue_name))                  # Processing size
          pipe.zcard("#{queue_name}:failed")                       # Failed count
          pipe.zcard("#{queue_name}:dead_letter")                  # Dead letter count
          pipe.hget("joobq:stats:processed", queue_name)           # Processed count
        end
      end

      # Parse results into metrics
      queue_names.each_with_index do |queue_name, queue_index|
        base_index = queue_index * 5
        queue_size = results[base_index].as(Int64)
        processing_size = results[base_index + 1].as(Int64)
        failed_count = results[base_index + 2].as(Int64)
        dead_letter_count = results[base_index + 3].as(Int64)
        processed_str = results[base_index + 4]
        processed_count = processed_str ? processed_str.as(String).to_i64 : 0i64

        metrics[queue_name] = QueueMetrics.new(
          queue_size, processing_size, failed_count, dead_letter_count, processed_count
        )
      end

      metrics
    rescue ex
      Log.error &.emit("Error collecting queue metrics", queue_count: queue_names.size, error: ex.message)
      {} of String => QueueMetrics
    end

    # Get metrics for a single queue
    def get_queue_metrics(queue_name : String) : QueueMetrics
      get_queue_metrics_pipelined([queue_name])[queue_name]? || QueueMetrics.new(0, 0, 0, 0, 0)
    end

    # Get metrics for all configured queues using pipelining
    def get_all_queue_metrics : Hash(String, QueueMetrics)
      queue_names = JoobQ.config.queues.keys
      get_queue_metrics_pipelined(queue_names)
    end

    # Pipeline performance monitoring
    struct PipelineStats
      include JSON::Serializable
      getter total_pipeline_calls : Int64
      getter total_commands_batched : Int64
      getter average_batch_size : Float64
      getter pipeline_failures : Int64
      getter last_reset : Time

      def initialize(@total_pipeline_calls : Int64, @total_commands_batched : Int64,
                     @average_batch_size : Float64, @pipeline_failures : Int64, @last_reset : Time)
      end
    end

    # Pipeline performance tracking
    @@pipeline_stats = PipelineStats.new(0, 0, 0.0, 0, Time.local)

    def self.pipeline_stats : PipelineStats
      @@pipeline_stats
    end

    def self.reset_pipeline_stats : Nil
      @@pipeline_stats = PipelineStats.new(0, 0, 0.0, 0, Time.local)
    end

    def track_pipeline_operation(commands_count : Int32, success : Bool) : Nil
      @@pipeline_stats = PipelineStats.new(
        @@pipeline_stats.total_pipeline_calls + 1,
        @@pipeline_stats.total_commands_batched + commands_count,
        @@pipeline_stats.total_commands_batched.to_f / @@pipeline_stats.total_pipeline_calls,
        success ? @@pipeline_stats.pipeline_failures : @@pipeline_stats.pipeline_failures + 1,
        @@pipeline_stats.last_reset
      )
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
