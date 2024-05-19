module JoobQ
  module FailHandler
    def self.call(job, latency, ex : Exception)
      job.failed!
      track job, latency, ex

      if job.retries > 0
        Retry.attempt job
      else
        DeadLetter.add job
      end
    end

    private def self.track(job, start, ex)
      error = {
        queue:     job.queue,
        failed_at: Time.local,
        message:   ex.message,
        backtrace: ex.inspect_with_backtrace,
        cause:     ex.cause.to_s,
      }

      job.failed!
      store.failure(job, start, ex)

      Log.info &.emit("Failed", error)
    end
  end
end
