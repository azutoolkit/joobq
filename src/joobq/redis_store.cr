module JoobQ
  class RedisStore < Store
    DELAYED_SET      = "joobq:delayed_jobs"
    private DEAD_LETTER      = "joobq:dead_letter"
    private PROCESSING_QUEUE = "joobq:processing"
    private BLOCKING_TIMEOUT = 0.5

    # Health check interval for monitoring
    HEALTH_CHECK_INTERVAL = 5.seconds

    def self.instance : RedisStore
      @@instance ||= new
    end

    getter redis : Redis::PooledClient
    getter pool_size : Int32
    getter pool_timeout : Float64

    def initialize(@host : String = ENV.fetch("REDIS_HOST", "localhost"),
                   @port : Int32 = ENV.fetch("REDIS_PORT", "6379").to_i,
                   @password : String? = ENV["REDIS_PASS"]?,
                   @pool_size : Int32 = ENV.fetch("REDIS_POOL_SIZE", "500").to_i,
                   @pool_timeout : Float64 = ENV.fetch("REDIS_POOL_TIMEOUT", "2.0").to_f64)
      @redis = Redis::PooledClient.new(
        host: @host,
        port: @port,
        password: @password,
        pool_size: @pool_size,
        pool_timeout: @pool_timeout
      )

      # Log connection pool configuration
      Log.info &.emit("Redis store initialized",
        host: @host,
        port: @port,
        pool_size: @pool_size,
        pool_timeout: @pool_timeout
      )
    end

    # Connection pool health check with detailed metrics
    def health_check : Hash(String, String | Int32 | Bool | Float64)
      start_time = Time.monotonic

      begin
        # Try a simple ping
        redis.ping
        response_time = (Time.monotonic - start_time).total_milliseconds

        {
          "status"           => "healthy",
          "response_time_ms" => response_time.round(2),
          "pool_size"        => @pool_size,
          "pool_timeout"     => @pool_timeout,
          "connected"        => true,
          "pipeline_stats"   => @@pipeline_stats.to_json,
        }
      rescue ex
        {
          "status"         => "unhealthy",
          "error"          => ex.message || "Unknown error",
          "pool_size"      => @pool_size,
          "pool_timeout"   => @pool_timeout,
          "connected"      => false,
          "pipeline_stats" => @@pipeline_stats.to_json,
        }
      end
    end

    def reset : Nil
      redis.flushdb
    end

    def clear_queue(queue_name : String) : Nil
      redis.del(queue_name)
    end

    # Optimized method to clear multiple queues in a single pipeline
    def clear_queues_batch(queue_names : Array(String)) : Nil
      return if queue_names.empty?

      redis.pipelined do |pipe|
        queue_names.each do |queue_name|
          pipe.del(queue_name)
        end
      end
      track_pipeline_operation(queue_names.size, true)
    rescue ex
      track_pipeline_operation(queue_names.size, false)
      Log.error &.emit("Error clearing queues batch",
        queue_count: queue_names.size,
        error: ex.message)
      raise ex
    end

    def delete_job(job : String) : Nil
      parsed_job = JSON.parse(job)
      queue_name = parsed_job["queue"]?.try(&.as_s)
      return unless queue_name

      processing_key = processing_queue(queue_name)

      # Remove job from processing queue (all occurrences)
      redis.lrem(processing_key, 0, job)

      Log.debug &.emit("Job deleted",
        queue: queue_name,
        job_data_length: job.size
      )
    rescue ex
      Log.error &.emit("Error deleting job", error: ex.message)
    end

    def enqueue(job : Job) : String
      redis.rpush job.queue, job.to_json

      # Invalidate processing jobs cache
      invalidate_processing_cache

      Log.debug &.emit("Job enqueued", job_id: job.jid.to_s, queue: job.queue)
      job.jid.to_s
    end

    def enqueue_batch(jobs : Array(Job), batch_size : Int32 = 1000) : Nil
      raise "Batch size must be greater than 0" if batch_size <= 0
      raise "Batch size must be less than or equal to 1000" if batch_size > 1000

      return if jobs.empty?

      start_time = Time.monotonic
      total_enqueued = 0

      begin
        jobs.each_slice(batch_size) do |batch_jobs|
          redis.pipelined do |pipe|
            batch_jobs.each do |job|
              pipe.rpush job.queue, job.to_json
            end
          end
          total_enqueued += batch_jobs.size
        end

        duration = Time.monotonic - start_time
        Log.info &.emit("Batch enqueue successful",
          jobs_count: total_enqueued,
          duration_ms: duration.total_milliseconds.round(2),
          jobs_per_second: (total_enqueued / duration.total_seconds).round(2)
        )
      rescue ex
        Log.error &.emit("Batch enqueue failed",
          total_jobs: jobs.size,
          enqueued: total_enqueued,
          error: ex.message,
          error_class: ex.class.name
        )
        raise ex
      end
    end

    # High-performance reliable queue using BRPOPLPUSH
    def dequeue(queue_name : String, klass : Class) : String?
      processing_key = processing_queue(queue_name)

      # Use BRPOPLPUSH for reliable queue - blocks until job is available
      if job_data = redis.brpoplpush(queue_name, processing_key, BLOCKING_TIMEOUT)
        Log.debug &.emit("Job dequeued", queue: queue_name, job_data_length: job_data.to_s.size)
        return job_data.to_s
      end

      nil
    rescue ex
      Log.error &.emit("Error dequeuing job", queue: queue_name, error: ex.message)
      nil
    end

    # Batch dequeue for high performance - uses non-blocking operations
    def dequeue_batch(queue_name : String, klass : Class, batch_size : Int32 = 10) : Array(String)
      processing_key = processing_queue(queue_name)
      jobs = [] of String

      # Use pipelined RPOPLPUSH for batch operations
      redis.pipelined do |pipe|
        batch_size.times do
          pipe.rpoplpush(queue_name, processing_key)
        end
      end.each do |result|
        if result && !result.to_s.empty?
          jobs << result.to_s
        end
      end

      Log.debug &.emit("Batch dequeued jobs", queue: queue_name, count: jobs.size)
      jobs
    rescue ex
      Log.error &.emit("Error batch dequeuing jobs", queue: queue_name, error: ex.message)
      [] of String
    end

    def move_job_back_to_queue(queue_name : String) : Bool
      redis.brpoplpush(processing_queue(queue_name), queue_name, BLOCKING_TIMEOUT)
      true
    rescue
      false
    end

    def mark_as_dead(job : Job, expiration_time : Int64) : Nil
      redis.zadd DEAD_LETTER, expiration_time, job.to_json
      invalidate_dead_cache
    end

    def schedule(job : Job, delay_in_ms : Int64, delay_set : String = DELAYED_SET) : Nil
      redis.zadd delay_set, delay_in_ms, job.to_json
      invalidate_delayed_cache
    end

    def fetch_due_jobs(
      current_time = Time.local,
      delay_set : String = DELAYED_SET,
      limit : Int32 = 50,
      remove : Bool = true,
    ) : Array(String)
      score = current_time.to_unix_ms
      jobs = redis.zrangebyscore(delay_set, 0, score, with_scores: false, limit: [0, limit])
      if remove
        redis.zremrangebyscore(delay_set, "-inf", score)
        invalidate_delayed_cache
      end
      jobs.map &.as(String)
    end

    def queue_size(queue_name : String) : Int64
      redis.llen(queue_name)
    end

    def set_size(set_name : String) : Int64
      redis.zcard(set_name)
    end

    # Optimized batch queue sizes to reduce connection overhead
    def queue_sizes_batch(queue_names : Array(String)) : Hash(String, Int64)
      return {} of String => Int64 if queue_names.empty?

      sizes = {} of String => Int64

      results = redis.pipelined do |pipe|
        queue_names.each do |queue_name|
          pipe.llen(queue_name)
        end
      end

      queue_names.each_with_index do |queue_name, index|
        sizes[queue_name] = results[index].as(Int64)
      end

      track_pipeline_operation(queue_names.size, true)
      sizes
    rescue ex
      track_pipeline_operation(queue_names.size, false)
      Log.error &.emit("Error getting queue sizes batch",
        queue_count: queue_names.size,
        error: ex.message)
      {} of String => Int64
    end

    # Optimized batch set sizes to reduce connection overhead
    def set_sizes_batch(set_names : Array(String)) : Hash(String, Int64)
      return {} of String => Int64 if set_names.empty?

      sizes = {} of String => Int64

      results = redis.pipelined do |pipe|
        set_names.each do |set_name|
          pipe.zcard(set_name)
        end
      end

      set_names.each_with_index do |set_name, index|
        sizes[set_name] = results[index].as(Int64)
      end

      track_pipeline_operation(set_names.size, true)
      sizes
    rescue ex
      track_pipeline_operation(set_names.size, false)
      Log.error &.emit("Error getting set sizes batch",
        set_count: set_names.size,
        error: ex.message)
      {} of String => Int64
    end

    # Simplified job cleanup for BRPOPLPUSH pattern - just remove from processing queue
    def cleanup_job(job_json : String, queue_name : String) : Nil
      processing_key = processing_queue(queue_name)

      # Extract job ID for logging
      job_id = nil
      begin
        parsed = JSON.parse(job_json)
        job_id = parsed["jid"]?.try(&.as_s)
      rescue
        # Continue without job_id if parsing fails
      end

      redis.pipelined do |pipe|
        # Remove job from processing queue (all occurrences)
        pipe.lrem(processing_key, 0, job_json)

        # Update statistics
        pipe.hincrby("joobq:stats:processed", queue_name, 1)
        pipe.hincrby("joobq:stats:total_processed", "global", 1)
      end

      Log.debug &.emit("Job cleanup successful",
        queue: queue_name,
        job_id: job_id || "unknown"
      )
    rescue ex
      Log.error &.emit("Error cleaning up job",
        queue: queue_name,
        error: ex.message
      )
    end

    # Batch job cleanup for high performance
    def cleanup_jobs_batch(job_jsons : Array(String), queue_name : String) : Nil
      return if job_jsons.empty?

      processing_key = processing_queue(queue_name)

      redis.pipelined do |pipe|
        # Remove all jobs from processing queue
        job_jsons.each do |job_json|
          pipe.lrem(processing_key, 0, job_json)
        end

        # Update statistics
        pipe.hincrby("joobq:stats:processed", queue_name, job_jsons.size)
        pipe.hincrby("joobq:stats:total_processed", "global", job_jsons.size)
      end

      Log.debug &.emit("Batch job cleanup successful",
        queue: queue_name,
        job_count: job_jsons.size
      )
    rescue ex
      Log.error &.emit("Error in batch job cleanup",
        queue: queue_name,
        job_count: job_jsons.size,
        error: ex.message
      )
    end

    # Mark job as completed with statistics
    def mark_job_completed(job_json : String, queue_name : String) : Nil
      processing_key = processing_queue(queue_name)

      # Extract job ID for logging
      job_id = nil
      begin
        parsed = JSON.parse(job_json)
        job_id = parsed["jid"]?.try(&.as_s)
      rescue
        # Continue without job_id if parsing fails
      end

      redis.pipelined do |pipe|
        # Remove job from processing queue
        pipe.lrem(processing_key, 0, job_json)

        # Update completion statistics
        pipe.hincrby("joobq:stats:completed", queue_name, 1)
        pipe.hincrby("joobq:stats:total_completed", "global", 1)
        pipe.hincrby("joobq:stats:processed", queue_name, 1)
        pipe.hincrby("joobq:stats:total_processed", "global", 1)
      end

      Log.debug &.emit("Job marked as completed",
        queue: queue_name,
        job_id: job_id || "unknown"
      )
    rescue ex
      Log.error &.emit("Error marking job as completed",
        queue: queue_name,
        error: ex.message
      )
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

    # Connection reuse optimization: Batch multiple single operations into pipelines
    # This reduces connection overhead for operations that don't need to be immediate
    private def batch_operations(operations : Array(Proc(Nil)), max_batch_size : Int32 = 10) : Nil
      return if operations.empty?

      # Process operations in batches to optimize connection reuse
      operations.each_slice(max_batch_size) do |batch|
        redis.pipelined do |_|
          batch.each do |operation|
            operation.call
          end
        end
        track_pipeline_operation(batch.size, true)
      end
    rescue ex
      track_pipeline_operation(operations.size, false)
      Log.error &.emit("Error in batch operations", error: ex.message)
      raise ex
    end

    # Connection pooling optimization: Execute multiple read operations in a single pipeline
    # This is ideal for operations that can tolerate slightly stale data
    def execute_read_operations_batch(operations : Array(-> Redis::RedisValue)) : Array(Redis::RedisValue)
      return [] of Redis::RedisValue if operations.empty?

      results = redis.pipelined do |_|
        operations.each do |operation|
          # Note: This is a simplified approach - in practice, you'd need to adapt
          # the operations to work with the pipeline interface
          operation.call
        end
      end
      track_pipeline_operation(operations.size, true)
      results
    rescue ex
      track_pipeline_operation(operations.size, false)
      Log.error &.emit("Error in read operations batch", error: ex.message)
      [] of Redis::RedisValue
    end

    # Optimized connection reuse for statistics collection
    def collect_statistics_batch : Hash(String, Int64)
      stats = {} of String => Int64

      # Collect multiple statistics in a single pipeline
      results = redis.pipelined do |pipe|
        # Queue sizes for all configured queues
        JoobQ.queues.each do |queue_name, _|
          pipe.llen(queue_name)
          pipe.llen(processing_queue(queue_name))
        end

        # Set sizes for delayed and dead jobs
        pipe.zcard(DELAYED_SET)
        pipe.zcard(DEAD_LETTER)

        # Global statistics
        pipe.hget("joobq:stats:total_processed", "global")
        pipe.hget("joobq:stats:total_completed", "global")
        pipe.hget("joobq:stats:total_retries", "global")
        pipe.hget("joobq:stats:total_dead_letter", "global")
      end

      result_index = 0

      # Parse queue statistics
      JoobQ.queues.each do |queue_name, _|
        stats["#{queue_name}_size"] = results[result_index].as(Int64)
        result_index += 1
        stats["#{queue_name}_processing"] = results[result_index].as(Int64)
        result_index += 1
      end

      # Parse set statistics
      stats["delayed_jobs"] = results[result_index].as(Int64)
      result_index += 1
      stats["dead_jobs"] = results[result_index].as(Int64)
      result_index += 1

      # Parse global statistics
      stats["total_processed"] = results[result_index]?.try(&.as(String).to_i64) || 0i64
      result_index += 1
      stats["total_completed"] = results[result_index]?.try(&.as(String).to_i64) || 0i64
      result_index += 1
      stats["total_retries"] = results[result_index]?.try(&.as(String).to_i64) || 0i64
      result_index += 1
      stats["total_dead_letter"] = results[result_index]?.try(&.as(String).to_i64) || 0i64

      track_pipeline_operation(results.size, true)
      stats
    rescue ex
      track_pipeline_operation(10, false) # Approximate command count
      Log.error &.emit("Error collecting statistics batch", error: ex.message)
      {} of String => Int64
    end

    def processing_list(pattern : String = "#{PROCESSING_QUEUE}:*", limit : Int32 = 100) : Array(String)
      processing_list_paginated(0, limit, pattern)
    end

    # Get processing jobs with pagination support
    def processing_list_paginated(offset : Int32, limit : Int32, pattern : String = "#{PROCESSING_QUEUE}:*") : Array(String)
      jobs_collected = [] of String
      current_offset = 0
      target_offset = offset

      # Step 1: Use SCAN instead of KEYS to avoid blocking Redis
      # SCAN is O(1) per call and doesn't block the server
      cursor = 0_i64
      processing_keys = [] of String

      loop do
        # SCAN returns [new_cursor, [keys]]
        result = redis.scan(cursor, match: pattern, count: 100)
        cursor = result[0].as(String).to_i64
        keys = result[1].as(Array)

        keys.each do |key|
          key_str = key.as(String)
          # Only process actual processing queue keys (not worker claim keys)
          if key_str.count(':') == 2
            processing_keys << key_str
          end
        end

        # Break if cursor is back to 0 (full iteration complete)
        break if cursor == 0
      end

      # Step 2: Collect jobs from each processing queue with pagination
      processing_keys.each do |key_string|
        break if jobs_collected.size >= limit # Stop if we've collected enough jobs

        # Check if the key is a list
        key_type = redis.type(key_string)
        next unless key_type == "list"

        # Get the total length of this queue
        queue_length = redis.llen(key_string).to_i

        # Skip this queue if we haven't reached the target offset yet
        if current_offset + queue_length <= target_offset
          current_offset += queue_length
          next
        end

        # Calculate how many jobs to skip from this queue
        queue_skip = [target_offset - current_offset, 0].max
        remaining_needed = limit - jobs_collected.size
        queue_take = [queue_length - queue_skip, remaining_needed].min

        if queue_take > 0
          # Get jobs from this queue with proper offset and limit
          queue_jobs = redis.lrange(key_string, queue_skip, queue_skip + queue_take - 1)
          jobs_collected.concat(queue_jobs.map &.as(String))
        end

        current_offset += queue_length
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

    # Remove job from processing queue by job ID (more reliable than JSON match)
    private def remove_job_from_processing_by_id(job_id : String, queue_name : String) : Bool
      processing_key = processing_queue(queue_name)

      # Get all jobs from processing queue
      jobs = redis.lrange(processing_key, 0, -1)

      # Find and remove the job with matching ID
      jobs.each do |job_json|
        begin
          job_data = JSON.parse(job_json.to_s)
          if job_data["jid"]?.to_s == job_id
            redis.lrem(processing_key, 0, job_json.to_s)
            return true
          end
        rescue
          # Skip invalid JSON entries
          next
        end
      end

      false
    end

    # High-performance move to dead letter queue using pipelined operations
    def move_to_dead_letter(job : Job, queue_name : String) : Nil
      current_timestamp = Time.local.to_unix_ms
      job_json = job.to_json
      retry_lock_key = "joobq:retry_lock:#{job.jid}"

      # Remove job by ID from processing queue (more reliable than JSON match)
      remove_job_from_processing_by_id(job.jid.to_s, queue_name)

      redis.pipelined do |pipe|
        # Add to dead letter queue
        pipe.zadd(DEAD_LETTER, current_timestamp, job_json)

        # Clean up retry lock if it exists
        pipe.del(retry_lock_key)

        # Update statistics
        pipe.hincrby("joobq:stats:dead_letter", queue_name, 1)
        pipe.hincrby("joobq:stats:total_dead_letter", "global", 1)
      end

      Log.debug &.emit("Job moved to dead letter queue",
        job_id: job.jid.to_s,
        queue: queue_name
      )
    rescue ex
      Log.error &.emit("Failed to move job to dead letter queue",
        job_id: job.jid.to_s,
        queue: queue_name,
        error: ex.message
      )
      raise ex
    end

    # High-performance move to retry queue using pipelined operations
    def move_to_retry(job : Job, queue_name : String, delay_ms : Int64) : Bool
      schedule_time = Time.local.to_unix_ms + delay_ms
      job_json = job.to_json

      # Remove job by ID from processing queue (more reliable than JSON match)
      remove_job_from_processing_by_id(job.jid.to_s, queue_name)

      redis.pipelined do |pipe|
        # Add to delayed queue with future timestamp
        pipe.zadd(DELAYED_SET, schedule_time, job_json)

        # Update statistics
        pipe.hincrby("joobq:stats:retries", queue_name, 1)
        pipe.hincrby("joobq:stats:total_retries", "global", 1)
      end

      Log.debug &.emit("Job moved to retry queue",
        job_id: job.jid.to_s,
        queue: queue_name,
        delay_ms: delay_ms,
        schedule_time: schedule_time
      )

      # Invalidate caches since data has changed
      invalidate_processing_cache
      invalidate_delayed_cache

      true
    rescue ex
      Log.error &.emit("Failed to move job to retry queue",
        job_id: job.jid.to_s,
        queue: queue_name,
        error: ex.message
      )
      false
    end

    # Schedule delayed retry - simplified version of move_to_retry
    def schedule_delayed_retry(job : Job, queue_name : String, delay_ms : Int64) : Bool
      move_to_retry(job, queue_name, delay_ms)
    end

    # Implement abstract method - use dequeue with BRPOPLPUSH
    def claim_job(queue_name : String, worker_id : String, klass : Class) : String?
      dequeue(queue_name, klass)
    end

    # Implement abstract method - use batch dequeue
    def claim_jobs_batch(queue_name : String, worker_id : String, klass : Class, batch_size : Int32 = 5) : Array(String)
      dequeue_batch(queue_name, klass, batch_size)
    end

    # Implement abstract method - no-op for BRPOPLPUSH pattern
    def release_job_claim(queue_name : String, worker_id : String) : Nil
      # No-op: BRPOPLPUSH pattern doesn't require explicit claim release
    end

    # Implement abstract method - no-op for BRPOPLPUSH pattern
    def release_job_claims_batch(queue_name : String, worker_id : String, job_count : Int32) : Nil
      # No-op: BRPOPLPUSH pattern doesn't require explicit claim release
    end

    # Process due jobs from delayed queue and move them back to main queue
    # Jobs are moved back with "enqueued" status so workers can pick them up
    # Returns the array of job JSON strings that were moved
    def process_due_delayed_jobs(queue_name : String) : Array(String)
      current_time = Time.local.to_unix_ms
      due_jobs = [] of String
      moved_count = 0

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
                # Update job status from "retrying" to "enqueued" so workers pick it up
                # Build a mutable hash from the parsed JSON
                job_data = Hash(String, JSON::Any).new
                parsed_job.as_h.each do |key, value|
                  job_data[key] = value
                end

                # Update status to "Enqueued" (capitalized to match Crystal enum serialization)
                job_data["status"] = JSON::Any.new("Enqueued")
                updated_job_json = job_data.to_json

                # Remove from delayed queue (using original JSON)
                pipe.zrem(DELAYED_SET, job_json)

                # Add back to main queue with updated status (front of queue for priority)
                pipe.lpush(queue_name, updated_job_json)

                moved_count += 1
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
          count: moved_count
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
        "main_queue"  => 0,
        "processing"  => 0,
        "delayed"     => 0,
        "dead_letter" => 0,
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

    # Cache invalidation helpers with connection reuse optimization
    private def invalidate_processing_cache : Nil
      JoobQ.api_cache.invalidate_processing_jobs
    rescue ex
      Log.warn &.emit("Failed to invalidate processing cache", error: ex.message)
    end

    private def invalidate_delayed_cache : Nil
      JoobQ.api_cache.invalidate_delayed_jobs
    rescue ex
      Log.warn &.emit("Failed to invalidate delayed cache", error: ex.message)
    end

    private def invalidate_dead_cache : Nil
      JoobQ.api_cache.invalidate_dead_jobs
    rescue ex
      Log.warn &.emit("Failed to invalidate dead cache", error: ex.message)
    end

    # Optimized batch cache invalidation to reduce connection usage
    private def invalidate_caches_batch(cache_types : Array(String)) : Nil
      return if cache_types.empty?

      # Batch cache invalidations to minimize connection overhead
      cache_operations = cache_types.map do |cache_type|
        case cache_type
        when "processing"
          -> { invalidate_processing_cache }
        when "delayed"
          -> { invalidate_delayed_cache }
        when "dead"
          -> { invalidate_dead_cache }
        else
          -> { } # No-op for unknown cache types
        end
      end

      # Execute all cache invalidations in a single batch
      cache_operations.each(&.call)
    rescue ex
      Log.warn &.emit("Failed to invalidate caches batch",
        cache_types: cache_types.join(","),
        error: ex.message)
    end

    # Optimized method to get processing jobs count across all processing queues
    def get_processing_jobs_count : Int32
      total_count = 0
      cursor = 0_i64

      loop do
        # Use SCAN to get processing queue keys without blocking Redis
        result = redis.scan(cursor, match: "joobq:processing:*", count: 100)
        cursor = result[0].as(String).to_i64
        keys = result[1].as(Array)

        # Use pipelining to get counts from multiple queues at once
        if !keys.empty?
          counts = redis.pipelined do |pipe|
            keys.each do |key|
              # Only count actual processing queue keys (not worker claim keys)
              if key.as(String).count(':') == 2
                pipe.llen(key.as(String))
              else
                pipe.echo("0") # Placeholder for non-queue keys
              end
            end
          end

          total_count += counts.sum { |count| count.as(Int64).to_i }
        end

        # Break if cursor is back to 0 (full iteration complete)
        break if cursor == 0
      end

      total_count
    rescue ex
      Log.warn &.emit("Error getting processing jobs count", error: ex.message)
      0
    end

    # Simple retrying jobs count - get all delayed jobs and count those with Retrying status
    def get_retrying_jobs_count : Int32
      all_jobs = redis.zrange(DELAYED_SET, 0, -1)
      retrying_count = 0

      all_jobs.each do |job_json|
        if job_json.as(String).includes?("\"status\":\"Retrying\"")
          retrying_count += 1
        end
      end

      retrying_count
    rescue ex
      Log.warn &.emit("Error getting retrying jobs count", error: ex.message)
      0
    end

    # Simple retrying jobs pagination - filter and paginate in memory
    def get_retrying_jobs_paginated(page : Int32, per_page : Int32) : Array(String)
      offset = (page - 1) * per_page
      all_jobs = redis.zrange(DELAYED_SET, 0, -1)
      retrying_jobs = [] of String

      all_jobs.each do |job_json|
        if job_json.as(String).includes?("\"status\":\"Retrying\"")
          retrying_jobs << job_json.as(String)
        end
      end

      retrying_jobs[offset, per_page]
    rescue ex
      Log.warn &.emit("Error getting retrying jobs paginated", error: ex.message)
      [] of String
    end

    # Simplified batch job lookup - search in all known locations
    def find_jobs_batch(jids : Array(String)) : Hash(String, String?)
      results = {} of String => String?
      jids.each { |jid| results[jid] = nil }

      # Search in main locations: delayed set, dead letter, and main queues
      locations = [DELAYED_SET, DEAD_LETTER]
      JoobQ.queues.each do |queue_name, _|
        locations << queue_name
      end

      locations.each do |location|
        key_type = redis.type(location)

        jobs = case key_type
               when "list"
                 redis.lrange(location, 0, -1)
               when "zset"
                 redis.zrange(location, 0, -1)
               else
                 [] of Redis::RedisValue
               end

        jobs.each do |job_json|
          job_str = job_json.as(String)
          jids.each do |jid|
            if job_str.includes?(jid) && results[jid].nil?
              results[jid] = job_str
            end
          end
        end
      end

      results
    rescue ex
      Log.warn &.emit("Error in batch job lookup", error: ex.message)
      results
    end

    # Helper method to get pipeline commands for state counts
    private def get_pipeline_commands_for_states(states : Array(String), pipe)
      states.each do |state|
        case state
        when "processing"
          pipe.echo("0") # Placeholder
        when "delayed"
          pipe.zcard(DELAYED_SET)
        when "retrying"
          pipe.echo("0") # Placeholder - handled separately
        when "failed"
          pipe.zcard("joobq:failed_jobs")
        when "dead"
          pipe.zcard(DEAD_LETTER)
        when "queued"
          pipe.echo("0") # Placeholder - handled separately
        else
          pipe.echo("0")
        end
      end
    end

    # Helper method to process state count results
    private def process_state_count_results(states : Array(String), pipe_results : Array(Redis::RedisValue)) : Hash(String, Int32)
      results = {} of String => Int32
      states.each { |state| results[state] = 0 }

      states.each_with_index do |state, index|
        results[state] = case state
                         when "processing"
                           get_processing_jobs_count
                         when "delayed"
                           pipe_results[index].as(Int64).to_i
                         when "retrying"
                           get_retrying_jobs_count
                         when "failed"
                           pipe_results[index].as(Int64).to_i
                         when "dead"
                           pipe_results[index].as(Int64).to_i
                         when "queued"
                           get_queued_jobs_count
                         else
                           0
                         end
      end

      results
    end

    # Helper method to get queued jobs count
    private def get_queued_jobs_count : Int32
      queue_counts = redis.pipelined do |pipe|
        JoobQ.queues.each do |queue_name, _|
          pipe.llen(queue_name)
        end
      end
      queue_counts.sum { |count| count.as(Int64).to_i }
    end

    # Optimized method to get job counts for multiple states at once
    def get_multiple_state_counts(states : Array(String)) : Hash(String, Int32)
      results = {} of String => Int32
      states.each { |state| results[state] = 0 }

      # Use pipelining to get all counts at once
      pipe_results = redis.pipelined do |pipe|
        get_pipeline_commands_for_states(states, pipe)
      end

      # Process results
      results = process_state_count_results(states, pipe_results)

      results
    rescue ex
      Log.warn &.emit("Error getting multiple state counts", error: ex.message)
      results
    end
  end
end
