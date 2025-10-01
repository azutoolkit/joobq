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
                jobs.each_slice(32) do |job_batch|
                  job_batch.each do |job|
                    spawn { handle_job_async(job) }
                  end
                  # Small delay between batches to allow connection reuse
                  sleep 1.microseconds if job_batch.size > 1
                end
              else
                # Adaptive delay to prevent busy waiting and reduce connection frequency
                sleep 1.microseconds
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
        begin
          parsed_job = T.from_json(job)
          parsed_job.running!

          middleware_pipeline.call(parsed_job, @queue, @worker_id) do
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
          # Always release the job claim and delete the job using pipelined cleanup
          parsed_job_id = parsed_job ? parsed_job.jid.to_s : job
          @queue.cleanup_job_processing_pipelined(@worker_id, parsed_job_id)
        end
      end
    end
  end
end
