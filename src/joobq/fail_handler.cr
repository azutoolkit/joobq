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

      if job.retries > 0
        job.retries = job.retries - 1
        queue.push job
        Log.warn &.emit("Retry", queue: job.queue, job_id: job.jid.to_s, retries_left: job.retries)
        queue.retried.add(1)
      else
        DeadLetter.add job
        queue.dead.add(1)
      end
    end
  end
end
