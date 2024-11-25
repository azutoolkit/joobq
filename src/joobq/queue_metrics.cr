require "redis"
require "json"
require "process"
require "system"

module JoobQ
  # Interface for metrics providers
  module MetricsProvider
    abstract def global_metrics : Hash(String, Int64 | Float64)
  end

  # Represents a class to handle queue metrics
  class QueueMetrics
    include MetricsProvider

    NON_METRIC_KEYS = %w[instance_id process_id last_updated started_at throttle_limit name job_type status]
    METRICS_KEY_PATTERN = "joobq:metrics:*"
    AVERAGES_METRICS = %w[
      jobs_completed_per_second errors_per_second enqueued_per_second
      job_wait_time job_execution_time worker_utilization
      error_rate_trend failed_job_rate percent_completed
      percent_retried percent_dead percent_busy
    ]

    def self.instance : QueueMetrics
      @@instance ||= new
    end

    @redis : Redis::PooledClient
    @instance_id : String
    @process_id : Int64
    @queues : Hash(String, JoobQ::BaseQueue)

    # Initialize with a Redis client and unique instance ID
    def initialize(instance_id : String = System.hostname)
      @redis = RedisStore.instance.redis
      @instance_id = instance_id
      @process_id = Process.pid
      @queues = JoobQ.config.queues
    end

    def run_metrics_collection : Nil
      spawn do
        loop do
          collect_and_store_metrics
          sleep(5)
        end
      end
      Log.info { "Queue metrics collection started..." }
    end

    # Collect and store queue metrics into Redis
    def collect_and_store_metrics
      timestamp = Time.local.to_unix

      @queues.values.each do |queue|
        metrics_key = "joobq:metrics:#{@instance_id}:#{@process_id}:#{queue.name}"
        queue_metrics = queue.info.to_h
        queue_metrics[:instance_id] = @instance_id
        queue_metrics[:process_id] = @process_id
        queue_metrics[:last_updated] = timestamp

        # Retrieve queue info and store in Redis
        @redis.hmset metrics_key, queue_metrics
      end
    end

    def all_queue_metrics :  Hash(String, Hash(String, String | Hash(String, Float64 | Int64)))
      result = Hash(String, Hash(String, String | Hash(String, Float64 | Int64))).new
      @queues.keys.each do |queue_name|
        result[queue_name] = queue_metrics(queue_name)
      end
      result
    end


    def queue_metrics(queue_name : String) : Hash(String, String | Hash(String, Float64 | Int64))
      queue = @queues[queue_name]

      result = Hash(String, String | Hash(String, Float64 | Int64)).new
      result["status"] = queue.status
      result["job_type"] = queue.job_type
      result["started_at"] = queue.metrics.start_time.from_now.to_s
      result["stats"]= aggregate_metrics(queue_name)
      result
    end



    # Aggregate metrics across all queues into a single hash
    def global_metrics : Hash(String, Float64 | Int64)
      data = metric_store

      @queues.keys.each do |queue_name|
        metrics = aggregate_metrics(queue_name)
        data.each do |key, _|
          data[key] += metrics[key]
        end
      end

      # Calculate averages for specific metrics
      queue_count = @queues.size
      if queue_count > 0
        AVERAGES_METRICS.each do |metric|
          (data[metric] /= queue_count).round(2)
        end
      end

      data
    end

    # Aggregate metrics across all instances for a particular queue
    def aggregate_metrics(queue_name : String) : Hash(String, Int64 | Float64)
      keys_pattern = "#{METRICS_KEY_PATTERN}:#{queue_name}"
      all_keys = scan_keys(keys_pattern)

      aggregated_metrics = metric_store
      count = 0

      responses = @redis.pipelined do |pipe|
        all_keys.each do |key|
          pipe.hgetall(key)
        end
      end

      responses.each do |metrics|
        # Ensure 'metrics' is an Array(Redis::RedisValue)
        metrics_array = metrics.as(Array(Redis::RedisValue))

        # Convert the array of key-value pairs into a hash
        metrics_array.each_slice(2) do |key_value|
          key = key_value[0].to_s
          value = key_value[1].to_s
          next if NON_METRIC_KEYS.includes?(key)
          aggregated_metrics[key] += value.includes?(".") ? (value.to_f64).round(2) : value.to_i64
        end

        count += 1
      end

      # Calculate average metrics where applicable
      if count > 0
        AVERAGES_METRICS.each do |metric|
          (aggregated_metrics[metric] /= count).round(2)
        end
      end

      aggregated_metrics
    end

    # Efficiently scan keys matching a pattern using SCAN instead of KEYS
    private def scan_keys(pattern : String) : Array(String)
      cursor = "0"
      keys = [] of String

      loop do
        response = @redis.scan(cursor, match: pattern, count: 1000)
        # 'response' is an Array(Redis::RedisValue)
        # The first element is the cursor, the second is the array of keys

        # Extract and convert the cursor
        cursor_value = response[0]
        cursor = cursor_value.is_a?(String) ? cursor_value : cursor_value.to_s

        # Extract and convert the results
        results_value = response[1]
        if results_value.is_a?(Array)
          results_value.each do |val|
            key = val.is_a?(String) ? val : val.to_s
            keys << key
          end
        end

        break if cursor == "0"
      end

      keys
    end

    # Initialize the metric store with default Float64 values
    private def metric_store : Hash(String, Float64 | Int64)
      {
        "total_workers"             => 0_i64,
        "current_size"              => 0_i64,
        "completed"                 => 0_i64,
        "retried"                   => 0_i64,
        "dead"                      => 0_i64,
        "running_workers"           => 0_i64,
        "jobs_completed_per_second" => 0.0,
        "queue_reduction_rate"      => 0.0,
        "errors_per_second"         => 0.0,
        "enqueued_per_second"       => 0.0,
        "job_wait_time"             => 0.0,
        "job_execution_time"        => 0.0,
        "worker_utilization"        => 0.0,
        "error_rate_trend"          => 0.0,
        "failed_job_rate"           => 0.0,
        "average_jobs_in_flight"    => 0.0,
        "percent_completed"         => 0.0,
        "percent_retried"           => 0.0,
        "percent_dead"              => 0.0,
        "percent_busy"              => 0.0,
      } of String => Float64 | Int64
    end
  end
end
