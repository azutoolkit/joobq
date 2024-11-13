module JoobQ
  module FailHandler
    def self.call(job, latency, ex : Exception, queue)
      job.failed!
      error = {
        queue:     job.queue,
        failed_at: Time.local,
        message:   ex.message,
        backtrace: ex.inspect_with_backtrace[0..10],
        cause:     ex.cause.to_s,
      }
      Log.info &.emit("Failed", queue: queue.name, job_id: job.jid.to_s, error: error)

      if job.expires && Time.local > job.expires
        DeadLetterManager.add(job)
        queue.dead.add(1)
        Log.error &.emit("Job expired and moved to Dead Letter Queue", job_id: job.jid.to_s)
      elsif job.retries > 0
        ExponentialBackoff.retry(job, queue)
        Log.warn &.emit("Retrying job", queue: queue.name, job_id: job.jid.to_s, retries_left: job.retries)
        queue.retried.add(1)
      else
        DeadLetterManager.add(job)
        queue.dead.add(1)
        Log.error &.emit("Job moved to Dead Letter Queue", job_id: job.jid.to_s)
      end
    end
  end

  class ExponentialBackoff
    def self.retry(job, queue)
      original_retries = job.retries
      retry_left = original_retries - 1
      job.retries = retry_left
      if retry_left > 0
        delay = (2 ** (original_retries - retry_left)) * 1000 # Delay in ms
        # Logic to add the job back to the queue after a delay
        queue.store.add_delayed(job, delay)
      end
    end
  end

  module DeadLetterManager
    def self.add(job)
      DeadLetter.add job.to_json
      Log.error &.emit("Job moved to Dead Letter Queue", job_id: job.jid.to_s)
    end
  end
end
