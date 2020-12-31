module JoobQ
  module Retry
    RETRY_SET = Sets::Retry.to_s
    REDIS     = JoobQ.redis

    def self.attempt(job, queue)
      count = job.retries
      job.retries = job.retries - 1
      at = retry_at(count)

      ## Update job
      Log.info &.emit("Retrying Job", in_seconds: "#{at}", job_id: "#{job.jid}", retries_left: "#{job.retries}")

      queue.set_job job.jid, job.to_json
      # Reschedule the job in the future
      JoobQ.scheduler.delay job, at
    end

    private def self.retry_at(count : Int32)
      ((count ** 4) + 15 + (rand(30)*(count + 1))).seconds
    end
  end
end
