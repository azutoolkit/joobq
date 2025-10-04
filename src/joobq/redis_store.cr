module JoobQ
  class RedisStore < Store
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
      remove : Bool = true,
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
    # IMPORTANT: job_json must be the FULL job JSON string, not just the job ID
    def cleanup_job_processing_pipelined(worker_id : String, job_json : String, queue_name : String) : Nil
      processing_key = processing_queue(queue_name)
      worker_claim_key = "#{processing_key}:#{worker_id}"

      redis.pipelined do |pipe|
        pipe.del(worker_claim_key)                               # Release claim
        pipe.lrem(processing_key, 0, job_json)                   # Remove ALL occurrences from processing
        pipe.hincrby("joobq:stats:processed", queue_name, 1)     # Update stats
        pipe.hincrby("joobq:stats:total_processed", "global", 1) # Update global stats
      end
    rescue ex
      Log.error &.emit("Error in pipelined job cleanup", queue: queue_name, worker: worker_id,
        job_data_length: job_json.size, error: ex.message)
    end

    # Enhanced job processing cleanup for successful completion
    # IMPORTANT: job_json must be the FULL job JSON string, not just the job ID
    def cleanup_completed_job_pipelined(worker_id : String, job_json : String, queue_name : String) : Nil
      processing_key = processing_queue(queue_name)
      worker_claim_key = "#{processing_key}:#{worker_id}"

      redis.pipelined do |pipe|
        # Release worker claim
        pipe.del(worker_claim_key)

        # Remove ALL occurrences of job from processing queue (ensures uniqueness)
        pipe.lrem(processing_key, 0, job_json)

        # Update completion statistics
        pipe.hincrby("joobq:stats:completed", queue_name, 1)
        pipe.hincrby("joobq:stats:total_completed", "global", 1)
        pipe.hincrby("joobq:stats:processed", queue_name, 1)
        pipe.hincrby("joobq:stats:total_processed", "global", 1)
      end
    rescue ex
      Log.error &.emit("Error in completed job cleanup", queue: queue_name, worker: worker_id,
        job_data_length: job_json.size, error: ex.message)
    end

    def list_jobs(queue_name : String, page_number : Int32 = 1, page_size : Int32 = 200) : Array(String)
      start_index = (page_number - 1) * page_size
      end_index = start_index + page_size - 1
      redis.lrange(queue_name, start_index, end_index).map &.as(String)
    end

    def list_sorted_set_jobs(set_name : String, page_number : Int32 = 1, page_size : Int32 = 200) : Array(String)
      start_index = (page_number - 1) * page_size
      end_index = start_index + page_size - 1
      redis.zrange(set_name, start_index, end_index).map &.as(String)
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
          pipe.llen(queue_name)                          # Queue size
          pipe.llen(processing_queue(queue_name))        # Processing size
          pipe.zcard("#{queue_name}:failed")             # Failed count
          pipe.zcard("#{queue_name}:dead_letter")        # Dead letter count
          pipe.hget("joobq:stats:processed", queue_name) # Processed count
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

      # Step 1: Get all processing queue keys matching the pattern
      processing_keys = redis.keys(pattern)

      # Step 2: Collect jobs from each processing queue until the limit is reached
      processing_keys.each do |processing_key|
        break if jobs_collected.size >= limit # Stop if we've collected enough jobs

        key_string = processing_key.as(String)

        # Skip worker claim keys (they have the pattern joobq:processing:queue_name:worker_id)
        # Only process actual processing queue keys (joobq:processing:queue_name)
        next if key_string.count(':') > 2

        # Check if the key is a list before trying to perform lrange
        key_type = redis.type(key_string)
        next unless key_type == "list"

        # Calculate remaining jobs to fetch
        remaining = limit - jobs_collected.size
        # Convert RedisValue to String and fetch jobs from the current processing queue
        queue_jobs = redis.lrange(key_string, 0, remaining - 1)
        jobs_collected.concat(queue_jobs.map &.as(String))
      end

      jobs_collected
    end

    # Verify that a job has been properly removed from processing queue
    def verify_job_removed_from_processing?(job_id : String, queue_name : String) : Bool
      processing_key = processing_queue(queue_name)

      # Check if job exists in processing queue
      jobs_in_processing = redis.lrange(processing_key, 0, -1)
      jobs_in_processing.none? { |job_data|
        begin
          parsed_job = JSON.parse(job_data.as(String))
          parsed_job["jid"]?.try(&.as_s) == job_id
        rescue
          false
        end
      }
    rescue ex
      Log.warn &.emit("Error verifying job removal from processing queue",
        job_id: job_id, queue: queue_name, error: ex.message)
      false
    end

    # Get count of jobs currently in processing queue
    def processing_queue_size(queue_name : String) : Int64
      processing_key = processing_queue(queue_name)
      redis.llen(processing_key)
    rescue ex
      Log.warn &.emit("Error getting processing queue size",
        queue: queue_name, error: ex.message)
      0i64
    end

    # Atomic operation: Move job from processing to dead letter queue
    # Uses pipelined operations to ensure atomicity and prevent partial failures
    # IMPORTANT: Removes job from ALL queues (processing, failed, delayed) to prevent re-enqueuing
    # IMPORTANT: Uses LREM with count=0 and ZREM to remove ALL occurrences of the job (ensures uniqueness)
    # original_job_json: The JSON of the job as it exists in the processing queue (before status changes)
    def move_to_dead_letter_atomic_with_original(job : Job, queue_name : String, original_job_json : String) : Nil
      processing_key = processing_queue(queue_name)
      retry_lock_key = "joobq:retry_lock:#{job.jid}"
      current_timestamp = Time.local.to_unix_ms
      # Use the modified job JSON for storing in dead letter queue
      modified_job_json = job.to_json

      redis.pipelined do |pipe|
        # Remove ALL occurrences of the job from processing queue using ORIGINAL JSON (ensures uniqueness)
        pipe.lrem(processing_key, 0, original_job_json)

        # Remove job from delayed/retry set using BOTH original and modified JSON (if it exists there)
        pipe.zrem(DELAYED_SET, original_job_json)
        pipe.zrem(DELAYED_SET, modified_job_json)

        # Add job to dead letter queue with timestamp score using MODIFIED JSON
        pipe.zadd(DEAD_LETTER, current_timestamp, modified_job_json)

        # Remove retry lock (cleanup)
        pipe.del(retry_lock_key)

        # Update statistics
        pipe.hincrby("joobq:stats:dead_letter", queue_name, 1)
        pipe.hincrby("joobq:stats:total_dead_letter", "global", 1)
      end

      Log.debug &.emit("Job moved to dead letter queue atomically (removed from all queues)",
        job_id: job.jid.to_s,
        queue: queue_name
      )
    rescue ex
      Log.error &.emit("Failed to move job to dead letter queue atomically",
        job_id: job.jid.to_s,
        queue: queue_name,
        error: ex.message
      )
      raise ex
    end

    # Backward compatible version that assumes the job hasn't changed
    def move_to_dead_letter_atomic(job : Job, queue_name : String) : Nil
      move_to_dead_letter_atomic_with_original(job, queue_name, job.to_json)
    end

    # Atomic operation: Move job from processing to retry/delayed queue
    # Uses pipelined operations to ensure atomicity and prevent partial failures
    # IMPORTANT: Uses LREM with count=0 to remove ALL occurrences of the job (ensures uniqueness)
    # original_job_json: The JSON of the job as it exists in the processing queue (before status changes)
    def move_to_retry_atomic_with_original(job : Job, queue_name : String, delay_ms : Int64, original_job_json : String) : Bool
      processing_key = processing_queue(queue_name)
      retry_lock_key = "joobq:retry_lock:#{job.jid}"
      schedule_time = Time.local.to_unix_ms + delay_ms
      # Use the modified job JSON for storing in delayed queue
      modified_job_json = job.to_json

      # Atomic operation using pipeline
      redis.pipelined do |pipe|
        # Remove ALL occurrences of the job from processing queue using ORIGINAL JSON (ensures uniqueness)
        pipe.lrem(processing_key, 0, original_job_json)

        # Add job to delayed/retry queue with future timestamp using MODIFIED JSON
        pipe.zadd(DELAYED_SET, schedule_time, modified_job_json)

        # Update retry statistics
        pipe.hincrby("joobq:stats:retries", queue_name, 1)
        pipe.hincrby("joobq:stats:total_retries", "global", 1)
      end

      Log.debug &.emit("Job moved to retry queue atomically",
        job_id: job.jid.to_s,
        queue: queue_name,
        delay_ms: delay_ms,
        schedule_time: schedule_time
      )

      true
    rescue ex
      Log.error &.emit("Failed to move job to retry queue atomically",
        job_id: job.jid.to_s,
        queue: queue_name,
        error: ex.message
      )
      # Remove retry lock on failure to allow future retry attempts
      redis.del(retry_lock_key) rescue nil
      false
    end

    # Backward compatible version that assumes the job hasn't changed
    def move_to_retry_atomic(job : Job, queue_name : String, delay_ms : Int64) : Bool
      move_to_retry_atomic_with_original(job, queue_name, delay_ms, job.to_json)
    end

    # Atomic operation: Cleanup retry lock
    def cleanup_retry_lock_atomic(job_id : UUID) : Nil
      retry_lock_key = "joobq:retry_lock:#{job_id}"
      redis.del(retry_lock_key)
    rescue ex
      Log.error &.emit("Failed to cleanup retry lock",
        job_id: job_id.to_s,
        error: ex.message
      )
    end

    # Schedule delayed retry (job status is already set to Retrying)
    # This method moves the job from processing queue to delayed queue
    def schedule_delayed_retry(job : Job, queue_name : String, delay_ms : Int64) : Bool
      processing_key = processing_queue(queue_name)
      schedule_time = Time.local.to_unix_ms + delay_ms
      job_json = job.to_json

      redis.pipelined do |pipe|
        # Remove from processing queue
        pipe.lrem(processing_key, 0, job_json)

        # Add to delayed queue with future timestamp
        pipe.zadd(DELAYED_SET, schedule_time, job_json)

        # Update statistics
        pipe.hincrby("joobq:stats:delayed_retries", queue_name, 1)
      end

      Log.debug &.emit("Job scheduled for delayed retry",
        job_id: job.jid.to_s,
        queue: queue_name,
        delay_ms: delay_ms,
        schedule_time: schedule_time
      )

      true
    rescue ex
      Log.error &.emit("Failed to schedule delayed retry",
        job_id: job.jid.to_s,
        queue: queue_name,
        error: ex.message
      )
      false
    end

    # Process due jobs from delayed queue and move them back to main queue
    # Returns the array of job JSON strings that were moved
    def process_due_delayed_jobs(queue_name : String) : Array(String)
      current_time = Time.local.to_unix_ms
      due_jobs = [] of String

      # Get jobs that are due for processing (score <= current_time)
      jobs_result = redis.zrangebyscore(DELAYED_SET, "-inf", current_time.to_s, limit: [0, 100])

      jobs_result.each do |job_data|
        due_jobs << job_data.as(String)
      end

      if !due_jobs.empty?
        redis.pipelined do |pipe|
          due_jobs.each do |job_json|
            # Parse job to check if it belongs to this queue
            begin
              parsed_job = JSON.parse(job_json)
              job_queue = parsed_job["queue"]?.try(&.as_s)

              # Only process jobs for this queue
              if job_queue == queue_name
                # Remove from delayed queue
                pipe.zrem(DELAYED_SET, job_json)

                # Add back to main queue (front of queue for priority)
                pipe.lpush(queue_name, job_json)
              end
            rescue ex
              Log.warn &.emit("Failed to parse delayed job",
                queue: queue_name,
                error: ex.message
              )
            end
          end
        end

        Log.debug &.emit("Processed due delayed jobs",
          queue: queue_name,
          count: due_jobs.size
        )
      end

      due_jobs
    rescue ex
      Log.error &.emit("Failed to process due delayed jobs",
        queue: queue_name,
        error: ex.message
      )
      [] of String
    end

    # Verify that a job exists in only one location (for debugging/testing)
    # Returns a hash with the job's locations
    def verify_job_uniqueness(job_jid : String, queue_name : String) : Hash(String, Int32)
      locations = {
        "main_queue"    => 0,
        "processing"    => 0,
        "delayed"       => 0,
        "dead_letter"   => 0,
      }

      # Check main queue
      main_jobs = redis.lrange(queue_name, 0, -1)
      locations["main_queue"] = main_jobs.count { |j| j.as(String).includes?(job_jid) }

      # Check processing queue
      processing_key = processing_queue(queue_name)
      processing_jobs = redis.lrange(processing_key, 0, -1)
      locations["processing"] = processing_jobs.count { |j| j.as(String).includes?(job_jid) }

      # Check delayed queue
      delayed_jobs = redis.zrange(DELAYED_SET, 0, -1)
      locations["delayed"] = delayed_jobs.count { |j| j.as(String).includes?(job_jid) }

      # Check dead letter queue
      dead_jobs = redis.zrange(DEAD_LETTER, 0, -1)
      locations["dead_letter"] = dead_jobs.count { |j| j.as(String).includes?(job_jid) }

      total_locations = locations.values.sum

      if total_locations > 1
        Log.warn &.emit("Job exists in multiple locations",
          job_id: job_jid,
          queue: queue_name,
          locations: locations.to_s
        )
      elsif total_locations == 0
        Log.debug &.emit("Job not found in any location",
          job_id: job_jid,
          queue: queue_name
        )
      end

      locations
    rescue ex
      Log.error &.emit("Error verifying job uniqueness",
        job_id: job_jid,
        queue: queue_name,
        error: ex.message
      )
      locations
    end

    private def processing_queue(name : String)
      "#{PROCESSING_QUEUE}:#{name}"
    end
  end
end
