module JoobQ
  module Middleware
    class AsyncLogging
      include Middleware

      def matches?(job : JoobQ::Job, queue : BaseQueue) : Bool
        true
      end

      def call(job : JoobQ::Job, queue : BaseQueue, next_middleware : ->) : Nil
        spawn do
          log_to_remote_service(job)
        end
        next_middleware.call
      end

      private def log_to_remote_service(job : JoobQ::Job)
        Log.info &.emit("Job enqueued", queue: job.queue, job_id: job.jid.to_s)
      end
    end
  end
end
