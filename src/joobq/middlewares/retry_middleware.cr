module JoobQ
  module Middleware
    class Retry
      include Middleware

      def matches?(job : JoobQ::Job, queue : BaseQueue) : Bool
        true # This middleware applies to all jobs
      end

      def call(job : JoobQ::Job, queue : BaseQueue, next_middleware : ->) : Nil
        begin
          next_middleware.call
        rescue ex : Exception
          handle_failure(job, queue, ex)
        end
      end

      private def handle_failure(job : JoobQ::Job, queue : BaseQueue, ex : Exception)
        Log.error &.emit("Job Failure", job_id: job.jid.to_s, error: ex.message)
        job.failed!
        job.retries -= 1

        job.error = {
          failed_at: Time.local.to_rfc3339,
          message:   ex.message,
          backtrace: ex.inspect_with_backtrace[0..10],
          cause:     ex.cause.to_s,
        }

        if job.retries > 0
          queue.metrics.increment_retried
          job.retrying!
          ExponentialBackoff.retry(job, queue)
        else
          queue.metrics.increment_dead
          DeadLetterManager.add(job)
        end
      end
    end
  end

  class ExponentialBackoff
    def self.retry(job, queue)
      delay = (2 ** (job.retries)) * 1000 # Delay in ms
      # Logic to add the job back to the queue after a delay
      queue.store.schedule(job, delay)
      # Log.warn &.emit("Job moved to Retry Queue", job_id: job.jid.to_s)
      Log.warn &.emit("Retrying Job", job_id: job.jid.to_s, retries_left: job.retries)
    end
  end
end
