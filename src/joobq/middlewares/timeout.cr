module JoobQ
  module Middleware
    class Timeout
      include Middleware

      def matches?(job : Job, queue : BaseQueue) : Bool
        true
      end

      def call(job : Job, queue : BaseQueue, worker_id : String, next_middleware : ->) : Nil
        if job.past_expiration?
          job.expired!

          # Record timeout error to error context
          timeout_error = Exception.new("Job expired after timeout")
          MonitoredErrorHandler.handle_job_error(
            job,
            queue,
            timeout_error,
            worker_id: worker_id,
            retry_count: 0,
            additional_context: {
              "middleware" => "timeout",
              "reason"     => "job_expired",
              "worker_id"  => worker_id,
            }
          )

          DeadLetterManager.add(job)
        else
          next_middleware.call
        end
      end
    end
  end
end
