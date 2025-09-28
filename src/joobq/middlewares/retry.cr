module JoobQ
  module Middleware
    class Retry
      include Middleware

      def matches?(job : JoobQ::Job, queue : BaseQueue) : Bool
        true # This middleware applies to all jobs
      end

      def call(job : JoobQ::Job, queue : BaseQueue, worker_id : String, next_middleware : ->) : Nil
        next_middleware.call
      rescue ex : Exception
        handle_failure(job, queue, ex, worker_id)
      end

      private def handle_failure(job : JoobQ::Job, queue : BaseQueue, ex : Exception, worker_id : String)
        # Calculate retry count (original retries - current retries)
        retry_count = job.retries - (job.retries || 0)

        # Use the monitored error handling system
        # For middleware errors, we need to provide a worker_id - use the provided worker_id
        error_context = MonitoredErrorHandler.handle_job_error(
          job,
          queue,
          ex,
          worker_id: worker_id,
          retry_count: retry_count,
          additional_context: {
            "middleware" => "retry",
            "original_retries" => job.retries.to_s,
            "worker_id" => worker_id
          }
        )
      end
    end
  end

  class ExponentialBackoff
    def self.retry(job, queue)
      delay = (2 ** (job.retries)) * 1000 # Delay in ms
      # Logic to add the job back to the queue after a delay
      queue.store.schedule(job, delay, delay_set: RedisStore::FAILED_SET)
    end
  end
end
