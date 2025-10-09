module JoobQ
  # Redis metrics collection and statistics
  class RedisMetrics
    DELAYED_SET      = "joobq:delayed_jobs"
    DEAD_LETTER      = "joobq:dead_letter"
    PROCESSING_QUEUE = "joobq:processing"

    def initialize(@redis : Redis::PooledClient)
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
      results = @redis.pipelined do |pipe|
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
      stats = {} of String => Int64

      # Collect multiple statistics in a single pipeline
      results = @redis.pipelined do |pipe|
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

      stats
    rescue ex
      Log.error &.emit("Error collecting statistics batch", error: ex.message)
      {} of String => Int64
    end

    # Optimized method to get processing jobs count using Lua script
    def get_processing_jobs_count : Int32
      # Use Lua script to efficiently count all processing jobs
      lua_script = <<-LUA
        local keys = redis.call('KEYS', 'joobq:processing:*')
        local total_count = 0

        for i = 1, #keys do
          local key = keys[i]
          -- Only count actual processing queue keys (not worker claim keys)
          if string.len(key) - string.len(string.gsub(key, ':', '')) == 2 then
            local count = redis.call('LLEN', key)
            total_count = total_count + count
          end
        end

        return total_count
      LUA

      @redis.eval(lua_script, [] of String, [] of String).as(Int32)
    rescue ex
      Log.warn &.emit("Error getting processing jobs count", error: ex.message)
      0
    end

    # Optimized retrying jobs count using Lua script for better performance
    def get_retrying_jobs_count : Int32
      # Use Lua script to count retrying jobs efficiently
      lua_script = <<-LUA
        local jobs = redis.call('ZRANGE', KEYS[1], 0, -1)
        local count = 0
        for i = 1, #jobs do
          if string.find(jobs[i], '"status":"Retrying"') then
            count = count + 1
          end
        end
        return count
      LUA

      @redis.eval(lua_script, [DELAYED_SET], [] of String).as(Int32)
    rescue ex
      Log.warn &.emit("Error getting retrying jobs count", error: ex.message)
      0
    end

    # Optimized retrying jobs pagination using Lua script
    def get_retrying_jobs_paginated(page : Int32, per_page : Int32) : Array(String)
      offset = (page - 1) * per_page

      # Use Lua script to filter and paginate retrying jobs efficiently
      lua_script = <<-LUA
        local jobs = redis.call('ZRANGE', KEYS[1], 0, -1)
        local retrying_jobs = {}
        for i = 1, #jobs do
          if string.find(jobs[i], '"status":"Retrying"') then
            table.insert(retrying_jobs, jobs[i])
          end
        end

        local start_idx = tonumber(ARGV[1]) + 1
        local end_idx = start_idx + tonumber(ARGV[2]) - 1

        local result = {}
        for i = start_idx, math.min(end_idx, #retrying_jobs) do
          table.insert(result, retrying_jobs[i])
        end

        return result
      LUA

      results = @redis.eval(lua_script, [DELAYED_SET], [offset.to_s, per_page.to_s])
      results.as(Array).map(&.as(String))
    rescue ex
      Log.warn &.emit("Error getting retrying jobs paginated", error: ex.message)
      [] of String
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
      queue_counts = @redis.pipelined do |pipe|
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
      pipe_results = @redis.pipelined do |pipe|
        get_pipeline_commands_for_states(states, pipe)
      end

      # Process results
      results = process_state_count_results(states, pipe_results)

      results
    rescue ex
      Log.warn &.emit("Error getting multiple state counts", error: ex.message)
      results
    end

    private def processing_queue(name : String)
      "#{PROCESSING_QUEUE}:#{name}"
    end
  end
end
