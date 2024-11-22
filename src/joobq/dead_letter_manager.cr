module JoobQ
  # The dead letter queue is a sorted set of job ids that have failed to be
  # processed. The score of the job id is the time at which the job was added
  # to the dead letter queue. The dead letter queue is used to track jobs that
  # have failed to be processed and to prevent the queue from growing
  # indefinitely.
  #
  # The dead letter queue is cleaned up by removing jobs that have been in the
  # queue for longer than the dead letter expiration time. The dead letter
  # expiration time is configurable and defaults to 7 days.
  module DeadLetterManager
    private class_getter expires : Int64 = ::JoobQ.config.dead_letter_ttl.to_i
    private class_getter store : Store = ::JoobQ.config.store

    def self.add(job)
      store.mark_as_dead(job, expires)
      Log.error &.emit("Job Moved to Dead Letter Queue", job_id: job.jid.to_s)
    end
  end
end
