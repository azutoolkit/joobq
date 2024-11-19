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

    def self.instance : QueueMetrics
      @@instance ||= new
    end

    @redis : Redis::PooledClient
    @instance_id : String
    @process_id : Int64
    @queues : Hash(String, JoobQ::BaseQueue)

    # Initialize with a Redis client and unique instance ID
    def initialize(instance_id : String = System.hostname)
      @redis = RedisStore.new.redis
      @instance_id = instance_id
      @process_id = Process.pid
      @queues = JoobQ.config.queues
    end

    # Collect and store queue metrics into Redis
    def collect_and_store_metrics
      timestamp = Time.utc.to_unix

      @queues.values.each do |queue|
        metrics_key = "joobq:metrics:#{@instance_id}:#{queue.name}"
        queue_metrics = queue.info.to_h
        queue_metrics[:instance_id] = @instance_id
        queue_metrics[:process_id] = @process_id
        queue_metrics[:last_updated] = timestamp
        queue_metrics.delete(:name)
        queue_metrics.delete(:status)

        # Retrieve queue info and store in Redis
        @redis.hmset metrics_key, queue_metrics
      end
    end

    # Modify this method to return a Hash instead of an Array
    def all_queue_metrics : Hash(String, Hash(String, String))
      all_metrics = Hash(String, Hash(String, String)).new

      @queues.each do |queue_name, _|
        all_metrics[queue_name] = queue_metrics(queue_name)
      end

      all_metrics
    end

    # Retrieve metrics for a specific queue
    def queue_metrics(queue_name : String) : Hash(String, String)
      metrics_key = "joobq:metrics:#{@instance_id}:#{queue_name}"
      @redis.hgetall(metrics_key)
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
        ["jobs_completed_per_second", "errors_per_second", "enqueued_per_second",
         "job_wait_time", "job_execution_time", "worker_utilization",
         "error_rate_trend", "failed_job_rate"].each do |metric|
          data[metric] /= queue_count
        end
      end

      data
    end

    # Aggregate metrics across all instances for a particular queue
    def aggregate_metrics(queue_name : String) : Hash(String, Int64 | Float64)
      keys_pattern = "joobq:metrics:*:#{queue_name}"
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
          unless ["instance_id", "process_id", "last_updated"].includes?(key)
            aggregated_metrics[key] += value.includes?(".") ? value.to_f64 : value.to_i64
          end
        end

        count += 1
      end

      # Calculate average metrics where applicable
      if count > 0
        ["jobs_completed_per_second", "errors_per_second", "enqueued_per_second",
         "job_wait_time", "job_execution_time", "worker_utilization",
         "error_rate_trend", "failed_job_rate"].each do |metric|
          aggregated_metrics[metric] /= count
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
        "total_workers"              => 0_i64,
        "current_size"               => 0_i64,
        "completed"                  => 0_i64,
        "retried"                    => 0_i64,
        "dead"                       => 0_i64,
        "running_workers"            => 0_i64,
        "jobs_completed_per_second"  => 0.0,
        "queue_reduction_rate"       => 0.0,
        "errors_per_second"          => 0.0,
        "enqueued_per_second"        => 0.0,
        "job_wait_time"              => 0.0,
        "job_execution_time"         => 0.0,
        "worker_utilization"         => 0.0,
        "error_rate_trend"           => 0.0,
        "failed_job_rate"            => 0.0,
        "average_jobs_in_flight" => 0.0,
      } of String => Float64 | Int64
    end
  end
end
