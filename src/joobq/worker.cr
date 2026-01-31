module JoobQ
  class Worker(T)
    Log = ::Log.for("WORKER")

    # Configuration constants for worker behavior
    private WORKER_BATCH_SLICE_SIZE = 32
    private WORKER_BATCH_DELAY      = 10.milliseconds
    private WORKER_IDLE_DELAY       = 100.milliseconds

    getter wid : Int32
    getter worker_id : String
    getter active : Atomic(Bool) = Atomic(Bool).new(false)
    getter running : Atomic(Bool) = Atomic(Bool).new(false)

    @terminate_channel : Channel(Nil)
    @queue : BaseQueue
    @worker_mutex = Mutex.new

    private getter middleware_pipeline : MiddlewarePipeline = JoobQ.config.middleware_pipeline

    def initialize(@wid : Int32, @terminate_channel : Channel(Nil), @queue : BaseQueue)
      @worker_id = "#{@queue.name}-worker-#{@wid}-#{UUID.random}"
    end

    def name
      @queue.name
    end

    def active? : Bool
      active.get
    end

    def running? : Bool
      running.get
    end

    def terminate
      @worker_mutex.synchronize do
        return unless active.get
        active.set(false)
        @terminate_channel.send nil
      end
    end

    def run
      # Atomic check-and-set to prevent race conditions
      @worker_mutex.synchronize do
        return if active.get || running.get
        active.set(true)
        running.set(true)
      end

      spawn do
        begin
          loop do
            select
            when @terminate_channel.receive?
              @worker_mutex.synchronize do
                active.set(false)
                running.set(false)
              end
              break
            else
              # Use batch processing for improved performance and minimal connection usage
              jobs = @queue.claim_jobs_batch(@worker_id, batch_size: JoobQ.config.worker_batch_size)

              if !jobs.empty?
                # Process jobs in smaller concurrent batches to reduce connection pressure
                jobs.each_slice(WORKER_BATCH_SLICE_SIZE) do |job_batch|
                  job_batch.each do |job|
                    # Spawn with error containment to prevent fiber crashes from affecting worker
                    spawn do
                      begin
                        handle_job_async(job)
                      rescue ex : Exception
                        Log.error &.emit("Unhandled error in job fiber",
                          queue: @queue.name,
                          worker_id: @worker_id,
                          error: ex.message,
                          error_class: ex.class.name)
                      end
                    end
                  end
                  # Small delay between batches to allow connection reuse
                  sleep WORKER_BATCH_DELAY if job_batch.size > 1
                end
              else
                # Adaptive delay to prevent busy waiting and reduce connection frequency
                sleep WORKER_IDLE_DELAY
              end
            end
          end
        rescue ex : Exception
          Log.error &.emit("Worker Error #{ex}", queue: @queue.name, worker_id: wid, reason: ex.message)
          @worker_mutex.synchronize do
            active.set(false)
            running.set(false)
          end
          @queue.worker_manager.restart self, ex
        ensure
          @worker_mutex.synchronize do
            active.set(false)
            running.set(false)
          end
        end
      end
    end

    # Async job handling for batch processing
    private def handle_job_async(job : String)
      spawn do
        parsed_job = nil
        job_completed_successfully = false
        begin
          parsed_job = T.from_json(job)
          parsed_job.running!

          middleware_pipeline.call(parsed_job, @queue, @worker_id) do
            parsed_job.perform
            parsed_job.completed!
            job_completed_successfully = true

            # Log successful completion
            Log.info &.emit("Job completed successfully",
              job_id: parsed_job.jid.to_s,
              queue: @queue.name,
              worker_id: @worker_id,
              processing_time: (Time.monotonic - parsed_job.enqueue_time).total_seconds.to_s)
          end
        rescue ex : JSON::Error
          # Handle unparseable jobs by moving them to dead letter queue
          handle_unparseable_job(job, ex)
          next
        rescue ex : Exception
          # Use the monitored error handling system with rich context
          if parsed_job
            error_context = MonitoredErrorHandler.handle_job_error(
              parsed_job,
              @queue,
              ex,
              worker_id: @worker_id,
              additional_context: {
                "worker_id"             => @worker_id,
                "job_data_length"       => job.size.to_s,
                "queue_workers"         => @queue.total_workers.to_s,
                "queue_running_workers" => @queue.running_workers.to_s,
                "processing_mode"       => "async_batch",
              }
            )

            # Log worker-specific error
            additional_context = {
              worker_wid:          wid.to_s,
              job_processing_time: (Time.monotonic - parsed_job.enqueue_time).total_seconds.to_s,
            }.to_h

            Log.error &.emit(
              "Worker async job processing failed",
              error_context.to_log_context.merge(additional_context)
            )
          else
            Log.error &.emit(
              "Worker async job processing failed - could not parse job",
              worker_id: @worker_id,
              job_data_length: job.size.to_s,
              error: ex.message || "Unknown error"
            )
          end
        ensure
          # Use appropriate cleanup method based on job completion status
          # IMPORTANT: Pass the full job JSON string, not just the job ID
          if job_completed_successfully && parsed_job
            # Use enhanced cleanup for successfully completed jobs
            @queue.cleanup_completed_job_pipelined(@worker_id, job)
          else
            # Use standard cleanup for failed or unparseable jobs
            @queue.cleanup_job_processing_pipelined(@worker_id, job)
          end
        end
      end
    end

    # Handle jobs that cannot be parsed (invalid JSON or structure)
    private def handle_unparseable_job(job_json : String, parse_error : Exception) : Nil
      Log.error &.emit("Unparseable job detected, moving to dead letter queue",
        queue: @queue.name,
        worker_id: @worker_id,
        job_data_length: job_json.size,
        parse_error: parse_error.message || "Unknown JSON parsing error"
      )

      # Try to extract job ID from the raw JSON if possible
      job_id = extract_job_id_from_raw_json(job_json)

      # Create a minimal error context for the unparseable job
      error_context = ErrorContext.new(
        job_id: job_id,
        queue_name: @queue.name,
        worker_id: @worker_id,
        job_type: "Unknown",
        error_type: "serialization_error",
        error_message: "Job could not be parsed: #{parse_error.message}",
        error_class: parse_error.class.name,
        backtrace: parse_error.inspect_with_backtrace.split('\n').first(10),
        retry_count: 0,
        job_data: job_json[0, 1000], # Truncate to first 1000 chars
        error_cause: nil,
        system_context: {
          "worker_id"         => @worker_id,
          "job_data_length"   => job_json.size.to_s,
          "parse_error_class" => parse_error.class.name,
        }
      )

      # Record the error in the error monitor
      JoobQ.error_monitor.record_error(error_context)

      # Move the unparseable job to dead letter queue
      move_unparseable_job_to_dead_letter(job_json, job_id)
    end

    # Extract job ID from raw JSON string
    private def extract_job_id_from_raw_json(job_json : String) : String
      # Try to extract jid field from the JSON string
      if match = job_json.match(/"jid"\s*:\s*"([^"]+)"/)
        match[1]
      elsif match = job_json.match(/"jid"\s*:\s*"([^"]+)"/)
        match[1]
      else
        # Generate a fallback ID based on content hash
        "unparseable_#{job_json.hash.abs.to_s(16)}"
      end
    rescue
      "unparseable_#{job_json.hash.abs.to_s(16)}"
    end

    # Move unparseable job to dead letter queue
    private def move_unparseable_job_to_dead_letter(job_json : String, job_id : String) : Nil
      # Create a minimal job structure for dead letter queue
      dead_job_data = {
        "jid"    => job_id,
        "queue"  => @queue.name,
        "status" => "Dead",
        "error"  => {
          "failed_at"      => Time.local.to_rfc3339,
          "message"        => "Job could not be parsed",
          "backtrace"      => "JSON parsing failed",
          "cause"          => "",
          "error_type"     => "serialization_error",
          "error_class"    => "JSON::Error",
          "retry_count"    => 0,
          "system_context" => {
            "worker_id"                => @worker_id,
            "original_job_data_length" => job_json.size.to_s,
          },
        },
        "original_job_data" => job_json[0, 1000], # Truncate for storage
      }

      # Store in dead letter queue
      redis_store = @queue.store
      if redis_store.is_a?(RedisStore)
        current_timestamp = Time.local.to_unix_ms
        redis_store.redis.zadd("joobq:dead_letter", current_timestamp, dead_job_data.to_json)

        Log.info &.emit("Unparseable job moved to dead letter queue",
          job_id: job_id,
          queue: @queue.name,
          worker_id: @worker_id
        )
      else
        Log.warn &.emit("Cannot move unparseable job to dead letter - RedisStore not available",
          job_id: job_id,
          queue: @queue.name,
          worker_id: @worker_id
        )
      end
    rescue ex
      Log.error &.emit("Failed to move unparseable job to dead letter queue",
        job_id: job_id,
        queue: @queue.name,
        worker_id: @worker_id,
        error: ex.message
      )
    end
  end
end
