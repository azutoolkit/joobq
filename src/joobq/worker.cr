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
              if job = @queue.claim_job(@worker_id)
                handle_job(job)
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
      ensure
        # Always release the job claim and delete the job
        @queue.release_job_claim(@worker_id)
        @queue.delete_job job
      end
    end
  end
end
