module JoobQ
  # Redis pipeline operations and performance tracking
  class RedisPipeline
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

    def initialize(@redis : Redis::PooledClient)
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
    def batch_operations(operations : Array(Proc(Nil)), max_batch_size : Int32 = 10) : Nil
      return if operations.empty?

      # Process operations in batches to optimize connection reuse
      operations.each_slice(max_batch_size) do |batch|
        @redis.pipelined do |_|
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

      results = @redis.pipelined do |_|
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

    # Optimized method to clear multiple queues in a single pipeline
    def clear_queues_batch(queue_names : Array(String)) : Nil
      return if queue_names.empty?

      @redis.pipelined do |pipe|
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

    # Optimized batch queue sizes to reduce connection overhead
    def queue_sizes_batch(queue_names : Array(String)) : Hash(String, Int64)
      return {} of String => Int64 if queue_names.empty?

      sizes = {} of String => Int64

      results = @redis.pipelined do |pipe|
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

      results = @redis.pipelined do |pipe|
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

    # Batch job cleanup for high performance
    def cleanup_jobs_batch(job_jsons : Array(String), queue_name : String) : Nil
      return if job_jsons.empty?

      processing_key = "joobq:processing:#{queue_name}"

      @redis.pipelined do |pipe|
        # Remove all jobs from processing queue
        job_jsons.each do |job_json|
          pipe.lrem(processing_key, 0, job_json)
        end

        # Update statistics
        pipe.hincrby("joobq:stats:processed", queue_name, job_jsons.size)
        pipe.hincrby("joobq:stats:total_processed", "global", job_jsons.size)
      end

      track_pipeline_operation(job_jsons.size + 2, true) # +2 for stats updates

      Log.debug &.emit("Batch job cleanup successful",
        queue: queue_name,
        job_count: job_jsons.size
      )
    rescue ex
      track_pipeline_operation(job_jsons.size + 2, false)
      Log.error &.emit("Error in batch job cleanup",
        queue: queue_name,
        job_count: job_jsons.size,
        error: ex.message
      )
    end

  end
end
