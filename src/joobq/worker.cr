module JoobQ
  class Worker(T)
    Log = ::Log.for("WORKER")

    getter wid : Int32
    getter active : Atomic(Bool) = Atomic(Bool).new(false)

    @terminate_channel : Channel(Nil)
    @queue : BaseQueue

    private getter middleware_pipeline : MiddlewarePipeline = JoobQ.config.middleware_pipeline

    def initialize(@wid : Int32, @terminate_channel : Channel(Nil), @queue : BaseQueue)
      @queue = queue
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
                handle_job(job)
              end
            end
          end
        rescue ex : Exception
          Log.error &.emit("Worker Error #{ex}", queue: @queue.name, worker_id: wid, reason: ex.message)
          @queue.worker_manager.restart self, ex
        end
      end
    end

    private def handle_job(job : String)
      parsed_job = T.from_json(job)
      parsed_job.running!

      middleware_pipeline.call(parsed_job, @queue) do
        parsed_job.perform
        parsed_job.completed!
      ensure
        @queue.delete_job job
      end
    end
  end
end
