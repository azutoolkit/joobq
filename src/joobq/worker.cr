module JoobQ
  class Worker(T)
    Log = ::Log.for("WORKER")

    getter wid : Int32
    getter active : Atomic(Bool) = Atomic(Bool).new(false)

    @terminate_channel : Channel(Nil)
    @queue : BaseQueue
    @metrics : Metrics

    private getter middleware_pipeline : MiddlewarePipeline = JoobQ.config.middleware_pipeline

    def initialize(@wid : Int32, @terminate_channel : Channel(Nil), @queue : BaseQueue, @metrics : Metrics)
      @queue = queue
      @metrics = metrics
      @terminate_channel = terminate_channel
    end

    def name
      @queue.name
    end

    def active? : Bool
      active.get
    end

    def terminate
      active.set(false)
      @terminate_channel.send nil
    end

    def run
      return if active?
      active.set(true)
      spawn do
        begin
          loop do
            select
            when @terminate_channel.receive?
              active.set(false)
              break
            else
              if job = @queue.next_job
                handle_job job
              end
            end
          end
        rescue ex : Exception
          Log.error &.emit("Worker Error", queue: @queue.name, worker_id: wid, reason: ex.message)
          @queue.worker_manager.restart self, ex
        end
      end
    end

    private def handle_job(job : String)
      parsed_job = T.from_json(job)
      parsed_job.running!

      middleware_pipeline.call(parsed_job, @queue) do
        @metrics.increment_busy
        execute parsed_job
      ensure
        @metrics.decrement_busy
        @queue.delete_job job
      end
    end

    private def execute(job : T)
      wait_time = Time.monotonic - job.enqueue_time
      @metrics.add_job_wait_time(wait_time)
      start_time = Time.monotonic

      begin
        job.perform
        job.completed!
        execution_time = Time.monotonic - start_time
        @metrics.add_job_execution_time(execution_time)
        @metrics.increment_completed
      rescue ex : Exception
        execution_time = Time.monotonic - start_time
        @metrics.add_job_execution_time(execution_time)
        raise ex # Allow middleware to handle failures
      end
    end
  end
end
