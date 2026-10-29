require "digest/sha1"

module JoobQ
  class RedisStore < Store
    DELAYED_SET      = "joobq:delayed_jobs"
    private DEAD_LETTER      = "joobq:dead_letter"
    private PROCESSING_QUEUE = "joobq:processing"
    private BLOCKING_TIMEOUT = 0.5

    # The configured store when it is a RedisStore, so classes that default to it talk to the same Redis as the
    # queues. Only before any configuration exists (or for another Store) is a store built from ENV.
    @@instance : RedisStore? = nil

    def self.instance : RedisStore
      JoobQ.configured_store?.as?(RedisStore) || (@@instance ||= from_env)
    end

    # The store the environment asks for: REDIS_URL (with REDIS_TLS_VERIFY and REDIS_CA_FILE) when it is set, otherwise
    # REDIS_HOST, REDIS_PORT and REDIS_PASS. A REDIS_URL that cannot be used raises `RedisEndpoint::Invalid` rather
    # than falling back to a plain connection to REDIS_HOST.
    def self.from_env : RedisStore
      url = ENV["REDIS_URL"]?.presence
      return new unless url

      new(url: url, verify: verify_setting(ENV["REDIS_TLS_VERIFY"]?, "REDIS_TLS_VERIFY") != false,
        ca_file: ENV["REDIS_CA_FILE"]?.presence)
    end

    # `true`/`1`/`yes`/`on` and `false`/`0`/`no`/`off` (any case); nil when `value` is unset or empty. Anything else
    # raises, because a misspelt "off" would otherwise be read as "on".
    def self.verify_setting(value : String?, name : String) : Bool?
      word = value.try(&.strip.downcase).presence
      return unless word
      return true if %w[true 1 yes on].includes?(word)
      return false if %w[false 0 no off].includes?(word)

      raise RedisEndpoint::Invalid.new("#{name} must be true or false")
    end

    # The parsed URL of a store made with `url:`; nil for one made with host and port.
    getter endpoint : RedisEndpoint? = nil

    getter redis : Redis::PooledClient
    getter host : String
    getter port : Int32
    getter pool_size : Int32
    getter pool_timeout : Float64
    getter health : RedisHealth
    getter pipeline : RedisPipeline
    getter metrics : RedisMetrics

    def initialize(@host : String = ENV.fetch("REDIS_HOST", "localhost"),
                   @port : Int32 = ENV.fetch("REDIS_PORT", "6379").to_i,
                   @password : String? = ENV["REDIS_PASS"]?,
                   @pool_size : Int32 = ENV.fetch("REDIS_POOL_SIZE", "500").to_i,
                   @pool_timeout : Float64 = ENV.fetch("REDIS_POOL_TIMEOUT", "2.0").to_f64,
                   connect_timeout : Time::Span = ENV.fetch("REDIS_CONNECT_TIMEOUT", "5.0").to_f64.seconds,
                   command_timeout : Time::Span = ENV.fetch("REDIS_COMMAND_TIMEOUT", "5.0").to_f64.seconds,
                   operation_timeout : Time::Span = ENV.fetch("REDIS_OPERATION_TIMEOUT", "5.0").to_f64.seconds)
      raise ArgumentError.new("Redis timeouts must be positive") if connect_timeout <= Time::Span.zero || command_timeout <= Time::Span.zero
      @redis = RedisPool.new(RedisEndpoint.new(@host, @port, password: @password),
        @pool_size, @pool_timeout, connect_timeout, command_timeout, operation_timeout)

      # Initialize specialized components
      @health = RedisHealth.new(@redis, @pool_size, @pool_timeout)
      @pipeline = RedisPipeline.new(@redis)
      @metrics = RedisMetrics.new(@redis)

      # Log connection pool configuration
      Log.info &.emit("Redis store initialized",
        host: @host,
        port: @port,
        pool_size: @pool_size,
        pool_timeout: @pool_timeout
      )
    end

    # Connects to the server a `redis://` or `rediss://` URL names (see `RedisEndpoint`): as an ACL user when the
    # URL has a user name, over TLS for `rediss`, on the database in its path. `verify` and `ca_file` control how
    # the server certificate is checked.
    def initialize(*, url : String, pool_size : Int32 = ENV.fetch("REDIS_POOL_SIZE", "500").to_i,
                   pool_timeout : Float64 = ENV.fetch("REDIS_POOL_TIMEOUT", "2.0").to_f64,
                   verify : Bool = true, ca_file : String? = nil,
                   connect_timeout : Time::Span = ENV.fetch("REDIS_CONNECT_TIMEOUT", "5.0").to_f64.seconds,
                   command_timeout : Time::Span = ENV.fetch("REDIS_COMMAND_TIMEOUT", "5.0").to_f64.seconds,
                   operation_timeout : Time::Span = ENV.fetch("REDIS_OPERATION_TIMEOUT", "5.0").to_f64.seconds)
      endpoint = RedisEndpoint.parse(url, verify, ca_file)
      @endpoint = endpoint
      @host = endpoint.host
      @port = endpoint.port
      @password = nil # the endpoint's clients hold the credentials; the store keeps none
      @pool_size = pool_size
      @pool_timeout = pool_timeout
      @redis = RedisPool.new(endpoint, pool_size, pool_timeout, connect_timeout, command_timeout, operation_timeout)

      @health = RedisHealth.new(@redis, @pool_size, @pool_timeout)
      @pipeline = RedisPipeline.new(@redis)
      @metrics = RedisMetrics.new(@redis)

      Log.info &.emit("Redis store initialized",
        endpoint: endpoint.to_s,
        pool_size: @pool_size,
        pool_timeout: @pool_timeout
      )
    end

    # Closes current connections for either constructor. Later commands reconnect.
    def close : Nil
      @redis.as?(RedisPool).try(&.close)
    end

    # Host, port and pool only: the default `inspect` would print the password this store was given.
    def inspect(io : IO) : Nil
      io << "#<" << self.class.name << ' ' << host << ':' << port << '>'
    end

    # Connection pool health check with detailed metrics
    def health_check : Hash(String, String | Int32 | Bool | Float64)
      health_data = @health.health_check
      health_data["pipeline_stats"] = RedisPipeline.pipeline_stats.to_json
      health_data
    end

    def reset : Nil
      redis.flushdb
    end

    def clear_queue(queue_name : String) : Nil
      redis.del(queue_name)
    end

    # Optimized method to clear multiple queues in a single pipeline
    def clear_queues_batch(queue_names : Array(String)) : Nil
      @pipeline.clear_queues_batch(queue_names)
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
      Events.emit("job.enqueued") { {jid: job.jid.to_s, queue: job.queue} }

      Log.debug &.emit("Job enqueued", job_id: job.jid.to_s, queue: job.queue)
      job.jid.to_s
    end

    def enqueue_batch(jobs : Array(Job), batch_size : Int32 = 1000, *, json_sizes : Array(Int32)? = nil) : Nil
      raise "Batch size must be greater than 0" if batch_size <= 0
      raise "Batch size must be less than or equal to 1000" if batch_size > 1000

      if sizes = json_sizes
        raise ArgumentError.new("json_sizes must contain one nonnegative capacity per job") unless sizes.size == jobs.size && sizes.all? { |size| size >= 0 }
      end

      return if jobs.empty?

      start_time = Time.instant
      total_enqueued = 0

      begin
        jobs.each_slice(batch_size) do |batch_jobs|
          redis.pipelined do |pipe|
            batch_jobs.each_with_index do |job, index|
              payload = if sizes = json_sizes
                          String.build(sizes[total_enqueued + index]) { |io| job.to_json(io) }
                        else
                          job.to_json
                        end
              pipe.rpush job.queue, payload
            end
          end
          total_enqueued += batch_jobs.size
          batch_jobs.each { |job| Events.emit("job.enqueued") { {jid: job.jid.to_s, queue: job.queue} } }
        end

        duration = Time.instant - start_time
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

    # Scored by time of death like every other dead-letter writer, so entries sort
    # and age consistently; `expiration_time` is kept for the Store interface.
    def mark_as_dead(job : Job, expiration_time : Int64) : Nil
      DeadLetterQueue.add(redis, Time.utc.to_unix_ms, [job.to_json])
    end

    def schedule(job : Job, delay_in_ms : Int64, delay_set : String = DELAYED_SET) : Nil
      redis.zadd delay_set, delay_in_ms, job.to_json
    end

    def schedule_job(job : String, schedule_time : Int64) : Nil
      redis.zadd DELAYED_SET, schedule_time, job
    end

    TAKE_DUE = <<-LUA
      local jobs = redis.call('ZRANGEBYSCORE', KEYS[1], 0, ARGV[1], 'LIMIT', 0, ARGV[2])
      for _, job in ipairs(jobs) do
        redis.call('ZREM', KEYS[1], job)
      end
      return jobs
    LUA

    def fetch_due_jobs(
      current_time = Time.local,
      delay_set : String = DELAYED_SET,
      limit : Int32 = 50,
      remove : Bool = true,
    ) : Array(String)
      score = current_time.to_unix_ms
      unless remove
        return redis.zrangebyscore(delay_set, 0, score, with_scores: false, limit: [0, limit]).map(&.as(String))
      end

      # Read and remove exactly the same members in one step: removing "everything due" after reading `limit` of
      # them would drop the rest unseen.
      redis.eval(TAKE_DUE, [delay_set], [score.to_s, limit.to_s]).as(Array).map(&.as(String))
    end

    def queue_size(queue_name : String) : Int64
      redis.llen(queue_name)
    end

    def set_size(set_name : String) : Int64
      redis.zcard(set_name)
    end

    # Optimized batch queue sizes to reduce connection overhead
    def queue_sizes_batch(queue_names : Array(String)) : Hash(String, Int64)
      @pipeline.queue_sizes_batch(queue_names)
    end

    # Optimized batch set sizes to reduce connection overhead
    def set_sizes_batch(set_names : Array(String)) : Hash(String, Int64)
      @pipeline.set_sizes_batch(set_names)
    end

    REQUEUE = <<-LUA
      if redis.call('LREM', KEYS[1], 1, ARGV[1]) == 1 then
        redis.call('RPUSH', KEYS[2], ARGV[1])
        return 1
      end
      return 0
    LUA

    # Puts a claimed job back at the end of its queue, in one step: it is taken off the processing list and pushed,
    # or (when it is no longer there, e.g. another process reclaimed it) nothing happens. Not counted as processed.
    def requeue_from_processing(job_json : String, queue_name : String) : Bool
      redis.eval(REQUEUE, [processing_queue(queue_name), queue_name], [job_json]) == 1
    end

    # Several `requeue_from_processing` in one script: KEYS are processing list and queue per entry, ARGV the jobs.
    # An entry whose commands fail (a key of the wrong type, say) is skipped inside the script, so one bad entry
    # neither stops the others nor produces an error reply; a pipeline would raise at the first error reply and
    # leave the connection with unread replies.
    REQUEUE_MANY = <<-LUA
      local n = 0
      for i = 1, #ARGV do
        local ok, removed = pcall(redis.call, 'LREM', KEYS[2 * i - 1], 1, ARGV[i])
        if ok and removed == 1 then
          if pcall(redis.call, 'RPUSH', KEYS[2 * i], ARGV[i]) then n = n + 1 end
        end
      end
      return n
    LUA

    REQUEUE_BATCH = 100

    # `requeue_from_processing` for many {queue, job} pairs; returns how many were put back. One script per
    # hundred entries; if a script itself fails, its entries are tried one by one and a failing one is logged and
    # skipped.
    def requeue_many_from_processing(entries : Array({String, String})) : Int32
      put_back = 0
      entries.each_slice(REQUEUE_BATCH) do |batch|
        begin
          keys = batch.flat_map { |(queue_name, _)| [processing_queue(queue_name), queue_name] }
          put_back += redis.eval(REQUEUE_MANY, keys, batch.map(&.last)).as(Int).to_i
        rescue ex
          Log.error &.emit("Batch requeue failed, requeuing one by one", error: ex.message)
          batch.each do |(queue_name, job_json)|
            put_back += 1 if requeue_from_processing(job_json, queue_name)
          rescue ex2
            Log.error &.emit("Could not requeue a job", queue: queue_name, error: ex2.message)
          end
        end
      end
      put_back
    end

    # Simplified job cleanup for BRPOPLPUSH pattern - just remove from processing queue
    def cleanup_job(job_json : String, queue_name : String) : Nil
      processing_key = processing_queue(queue_name)

      redis.pipelined do |pipe|
        # Remove job from processing queue (all occurrences)
        pipe.lrem(processing_key, 0, job_json)

        # Update statistics
        pipe.hincrby("joobq:stats:processed", queue_name, 1)
        pipe.hincrby("joobq:stats:total_processed", "global", 1)
      end

      Log.debug &.emit("Job cleanup successful",
        queue: queue_name,
        job_id: logging_job_id(job_json)
      )
    rescue ex
      Log.error &.emit("Error cleaning up job",
        queue: queue_name,
        error: ex.message
      )
    end

    # Batch job cleanup for high performance
    def cleanup_jobs_batch(job_jsons : Array(String), queue_name : String) : Nil
      @pipeline.cleanup_jobs_batch(job_jsons, queue_name)
    end

    # Mark job as completed with statistics
    def mark_job_completed(job_json : String, queue_name : String) : Nil
      processing_key = processing_queue(queue_name)

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
        job_id: logging_job_id(job_json)
      )
    rescue ex
      Log.error &.emit("Error marking job as completed",
        queue: queue_name,
        error: ex.message
      )
    end

    # Called only inside lazy debug log blocks; normal completion never parses a second JSON tree.
    private def logging_job_id(job_json : String) : String
      JSON.parse(job_json)["jid"]?.try(&.as_s) || "unknown"
    rescue
      "unknown"
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

    # Optimized connection reuse for statistics collection
    def collect_statistics_batch : Hash(String, Int64)
      @metrics.collect_statistics_batch
    end

    def processing_list(pattern : String = "#{PROCESSING_QUEUE}:*", limit : Int32 = 100) : Array(String)
      processing_list_paginated(0, limit, pattern)
    end

    # Optimized processing jobs list with batch operations
    def processing_list_paginated(offset : Int32, limit : Int32, pattern : String = "#{PROCESSING_QUEUE}:*") : Array(String)
      jobs_collected = [] of String
      current_offset = 0
      target_offset = offset

      # Step 1: Use SCAN to get processing queue keys
      cursor = 0_i64
      processing_keys = [] of String

      loop do
        result = redis.scan(cursor, match: pattern, count: 100)
        cursor = result[0].as(String).to_i64
        keys = result[1].as(Array)

        keys.each do |key|
          key_str = key.as(String)
          if key_str.count(':') == 2
            processing_keys << key_str
          end
        end

        break if cursor == 0
      end

      # Step 2: Batch collect jobs using pipelining for better performance
      if !processing_keys.empty?
        # Use pipelining to get queue lengths and types in batch
        queue_info = redis.pipelined do |pipe|
          processing_keys.each do |key|
            pipe.type(key)
            pipe.llen(key)
          end
        end

        # Process results and collect jobs efficiently
        processing_keys.each_with_index do |key_string, index|
          break if jobs_collected.size >= limit

          key_type = queue_info[index * 2].as(String)
          queue_length = queue_info[index * 2 + 1].as(Int64).to_i

          next unless key_type == "list"

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

    def paused?(queue_name : String) : Bool
      redis.exists(pause_key(queue_name)) == 1
    end

    def set_paused(queue_name : String, paused : Bool) : Nil
      paused ? redis.set(pause_key(queue_name), "1") : redis.del(pause_key(queue_name))
    end

    def desired_concurrency(queue_name : String) : {count: Int32, set_at: Int64}?
      count, set_at = redis.hmget(config_key(queue_name), "concurrency", "set_at")
      return unless count && set_at

      {count: count.to_s.to_i, set_at: set_at.to_s.to_i64}
    end

    def set_concurrency(queue_name : String, count : Int32) : Nil
      redis.hmset(config_key(queue_name), {"concurrency" => count.to_s, "set_at" => Time.utc.to_unix_ms.to_s})
    end

    private def config_key(queue_name : String) : String
      "joobq:queue:#{queue_name}:config"
    end

    private def pause_key(queue_name : String) : String
      "joobq:queue:#{queue_name}:paused"
    end

    # High-performance move to dead letter queue using pipelined operations
    def move_to_dead_letter(job : Job, queue_name : String) : Nil
      current_timestamp = Time.local.to_unix_ms
      job_json = job.to_json
      retry_lock_key = "joobq:retry_lock:#{job.jid}"

      # Persist the destination before acknowledging the source. If either write fails,
      # retain a recoverable copy; duplicates still require a fenced settlement protocol.
      DeadLetterQueue.add(redis, current_timestamp, [job_json])
      remove_job_from_processing_by_id(job.jid.to_s, queue_name)

      redis.pipelined do |pipe|
        # Clean up retry lock if it exists
        pipe.del(retry_lock_key)

        # Update statistics
        pipe.hincrby("joobq:stats:dead_letter", queue_name, 1)
        pipe.hincrby("joobq:stats:total_dead_letter", "global", 1)
      end

      Events.emit("job.dead") { {jid: job.jid.to_s, queue: queue_name} }
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

      # Store the retry first, then take the job off the processing list: a failure in between leaves the job
      # in processing (to be reclaimed or dead-lettered), never in neither place.
      redis.pipelined do |pipe|
        # Add to delayed queue with future timestamp
        pipe.zadd(DELAYED_SET, schedule_time, job_json)

        # Update statistics
        pipe.hincrby("joobq:stats:retries", queue_name, 1)
        pipe.hincrby("joobq:stats:total_retries", "global", 1)
      end

      # Remove job by ID from processing queue (more reliable than JSON match)
      remove_job_from_processing_by_id(job.jid.to_s, queue_name)

      Events.emit("job.retrying") { {jid: job.jid.to_s, queue: queue_name, delay_ms: delay_ms} }
      Log.debug &.emit("Job moved to retry queue",
        job_id: job.jid.to_s,
        queue: queue_name,
        delay_ms: delay_ms,
        schedule_time: schedule_time
      )

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

    # Source membership is the claim: competing schedulers cannot promote the same
    # member twice. Write the destination first: Lua does not roll back on errors.
    # JSON is parsed/re-encoded in Crystal, preserving Int64 values (Lua cjson uses doubles).
    PROMOTE_DUE = <<-LUA
      local score = redis.call('ZSCORE', KEYS[1], ARGV[1])
      if not score or tonumber(score) > tonumber(ARGV[3]) then return 0 end
      redis.call('RPUSH', KEYS[2], ARGV[2])
      redis.call('ZREM', KEYS[1], ARGV[1])
      return 1
    LUA

    def promote_due_jobs(current_time : Time = Time.utc, delay_set : String = DELAYED_SET,
                         queue_name : String? = nil, limit : Int32 = 50, *, report_scanned : Bool = false) : Array(String)
      scanned = fetch_due_jobs(current_time, delay_set, limit, remove: false)
      moved = Array(String).new(scanned.size)
      now = current_time.to_unix_ms.to_s
      scanned.each do |raw|
        begin
          next if queue_name && SerializedJob.queue_name(raw) != queue_name
          destination, payload = SerializedJob.for_enqueue(raw)
          if promote_due([delay_set, destination], [raw, payload, now]) == 1
            moved << raw
          end
        rescue ex
          # Malformed and unavailable destinations remain inspectable and retryable.
          Log.error &.emit("Delayed job promotion was not confirmed; inspect source and destination", delay_set: delay_set, error: ex.message)
        end
      end
      report_scanned ? scanned : moved
    end

    private PROMOTE_DUE_SHA = Digest::SHA1.hexdigest(PROMOTE_DUE)

    private def promote_due(keys : Array(String), args : Array(String))
      redis.evalsha(PROMOTE_DUE_SHA, keys, args)
    rescue ex : Redis::Error
      # A definite cache miss is safe to retry. Timeouts/ambiguous writes are not.
      raise ex unless ex.message.try(&.starts_with?("NOSCRIPT"))
      redis.eval(PROMOTE_DUE, keys, args)
    end

    # Preserve the legacy return contract: all scanned due jobs, including other queues.
    def process_due_delayed_jobs(queue_name : String) : Array(String)
      promote_due_jobs(queue_name: queue_name, report_scanned: true)
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

    # Optimized method to get processing jobs count using Lua script
    def get_processing_jobs_count : Int32
      @metrics.get_processing_jobs_count
    end

    # Optimized retrying jobs count using Lua script for better performance
    def get_retrying_jobs_count : Int32
      @metrics.get_retrying_jobs_count
    end

    # Optimized retrying jobs pagination using Lua script
    def get_retrying_jobs_paginated(page : Int32, per_page : Int32) : Array(String)
      @metrics.get_retrying_jobs_paginated(page, per_page)
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

    # Optimized method to get job counts for multiple states at once
    def get_multiple_state_counts(states : Array(String)) : Hash(String, Int32)
      @metrics.get_multiple_state_counts(states)
    end
  end
end
