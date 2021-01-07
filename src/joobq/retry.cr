module JoobQ
  module Retry
    extend self
    RETRY_SET = Sets::Retry.to_s
    REDIS     = JoobQ.redis

    def attempt(job)
      count = job.retries
      job.retries = job.retries - 1
      at = retry_at(count)

      Log.warn &.emit("Retry",
        queue: job.queue,
        job_id: "#{job.jid}",
        retry_in: "#{at}",
        retries_left: "#{job.retries}")

      JoobQ.scheduler.delay job, at
    end

    private def retry_at(count : Int32)
      ((count ** 4) + 15 + (rand(30)*(count + 1))).seconds
    end
  end
end
