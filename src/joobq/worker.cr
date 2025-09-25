module JoobQ
  class Worker(T)
    Log = ::Log.for("WORKER")

    getter wid : Int32
    getter worker_id : String
    getter active : Atomic(Bool) = Atomic(Bool).new(false)
    getter running : Atomic(Bool) = Atomic(Bool).new(false)

    @terminate_channel : Channel(Nil)
    @queue : BaseQueue
    @worker_mutex = Mutex.new

    private getter middleware_pipeline : MiddlewarePipeline = JoobQ.config.middleware_pipeline

    def initialize(@wid : Int32, @terminate_channel : Channel(Nil), @queue : BaseQueue)
      @queue = queue
      @terminate_channel = terminate_channel
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
              # Use batch processing for improved performance
              jobs = @queue.claim_jobs_batch(@worker_id, batch_size: JoobQ.config.worker_batch_size)

              if jobs.any?
                # Process jobs concurrently
                jobs.each do |job|
                  spawn { handle_job_async(job) }
                end
              else
                # Small delay to prevent busy waiting when no jobs available
                sleep 0.001.seconds
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

    private def handle_job(job : String)
      parsed_job = T.from_json(job)
      parsed_job.running!

      begin
        middleware_pipeline.call(parsed_job, @queue) do
          parsed_job.perform
          parsed_job.completed!
        end
      rescue ex : Exception
        # Use the monitored error handling system with rich context
        error_context = MonitoredErrorHandler.handle_job_error(
          parsed_job,
          @queue,
          ex,
          worker_id: @worker_id,
          additional_context: {
            "worker_id" => @worker_id,
            "job_data_length" => job.size.to_s,
            "queue_workers" => @queue.total_workers.to_s,
            "queue_running_workers" => @queue.running_workers.to_s
          }
        )

        # Log worker-specific error
        additional_context = {
          worker_wid: wid.to_s,
          job_processing_time: (Time.monotonic - parsed_job.enqueue_time).total_seconds.to_s
        }.to_h

        Log.error &.emit(
          "Worker job processing failed",
          error_context.to_log_context.merge(additional_context)
        )
      ensure
        # Always release the job claim and delete the job
        @queue.release_job_claim(@worker_id)
        @queue.delete_job job
      end
    end

    # Async job handling for batch processing
    private def handle_job_async(job : String)
      spawn do
        parsed_job = nil
        begin
          parsed_job = T.from_json(job)
          parsed_job.running!

          middleware_pipeline.call(parsed_job, @queue) do
            parsed_job.perform
            parsed_job.completed!
          end
        rescue ex : Exception
          # Use the monitored error handling system with rich context
          if parsed_job
            error_context = MonitoredErrorHandler.handle_job_error(
              parsed_job,
              @queue,
              ex,
              worker_id: @worker_id,
              additional_context: {
                "worker_id" => @worker_id,
                "job_data_length" => job.size.to_s,
                "queue_workers" => @queue.total_workers.to_s,
                "queue_running_workers" => @queue.running_workers.to_s,
                "processing_mode" => "async_batch"
              }
            )

            # Log worker-specific error
            additional_context = {
              worker_wid: wid.to_s,
              job_processing_time: (Time.monotonic - parsed_job.enqueue_time).total_seconds.to_s
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
              error: ex.message
            )
          end
        ensure
          # Always release the job claim and delete the job
          @queue.release_job_claim(@worker_id)
          @queue.delete_job job
        end
      end
    end
  end
end
