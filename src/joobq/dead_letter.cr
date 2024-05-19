module JoobQ
  # Document the job in the dead letter queue
  #
  # The dead letter queue is a sorted set of job ids that have failed to be
  # processed. The score of the job id is the time at which the job was added
  # to the dead letter queue. The dead letter queue is used to track jobs that
  # have failed to be processed and to prevent the queue from growing
  # indefinitely.
  #
  # The dead letter queue is cleaned up by removing jobs that have been in the
  # queue for longer than the dead letter expiration time. The dead letter
  # expiration time is configurable and defaults to 7 days.
  module DeadLetter
    private DEAD_LETTER = Sets::Dead.to_s

    def self.add(job)
      now = Time.local.to_unix_f
      expires = Config.dead_letter_expires.to_s

      joobq.redis.pipelined do |p|
        p.zadd DEAD_LETTER, now, job.jid.to_s
        p.zremrangebyscore DEAD_LETTER, "-inf", expires
        p.zremrangebyrank DEAD_LETTER, 0, -10_000
      end
    end
  end
end
