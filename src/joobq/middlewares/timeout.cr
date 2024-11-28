module JoobQ
  module Middleware
    class Timeout
      include Middleware

      def matches?(job : Job, queue : BaseQueue) : Bool
        true
      end

      def call(job : Job, queue : BaseQueue, next_middleware : ->) : Nil
        if job.expired?
          job.expired!
          DeadLetterManager.add(job)
          Log.info &.emit("Job has expired, added to dead letter queue",
            job_id: job.jid, status: job.status, expires: job.expires, retries: job.retries, queue: job.queue)
        else
          next_middleware.call
        end
      end
    end
  end
end
