module JoobQ
  # The jobs this process has claimed and not finished, with the queue each came from, so `JoobQ.shutdown` can
  # let them finish and, at its deadline, put the rest back on their queues.
  #
  # A claim is identified by a token, not by the job's raw string (two claims of the same string must not
  # collide). It is `claimed` from the moment its worker got the job from Redis (before any fiber exists for it),
  # `running` once its fiber began, and `abandoned` when shutdown gave up on it and returned it to its queue.
  #
  # An abandoned execution must be inert: its fiber must not start the job (if it has not yet), must not touch the
  # processing list when it ends (another process may have claimed the job since), and none of its failure or
  # success handling may schedule, dead-letter, count or announce anything, because the requeued copy owns the
  # job now. `abandoned?` (for the current fiber) is what that handling checks.
  module InFlight
    enum State
      Claimed
      Running
      Abandoned
    end

    record Entry, queue : String, job : String, state : State

    @@jobs = {} of Int64 => Entry
    @@fibers = {} of UInt64 => Int64
    @@next = 0_i64
    @@lock = Sync::Mutex.new

    # Jobs claimed or running (abandoned ones are not counted).
    def self.count : Int32
      @@lock.synchronize { @@jobs.count { |_, entry| !entry.state.abandoned? } }
    end

    # Registers freshly claimed jobs, one token each in the order given. Call it as soon as the claim returns.
    def self.claimed(queue : String, jobs : Array(String)) : Array(Int64)
      @@lock.synchronize do
        jobs.map do |job|
          token = (@@next += 1)
          @@jobs[token] = Entry.new(queue, job, State::Claimed)
          token
        end
      end
    end

    # The claim's fiber begins (the current fiber is remembered for `abandoned?`). False when shutdown abandoned
    # the claim first: do not run the job.
    def self.begin_run(token : Int64) : Bool
      @@lock.synchronize do
        entry = @@jobs[token]?
        return false if entry.nil? || entry.state.abandoned?

        @@jobs[token] = Entry.new(entry.queue, entry.job, State::Running)
        @@fibers[Fiber.current.object_id] = token
        true
      end
    end

    # The claim's fiber ends. True when shutdown had abandoned it (the job is already back on its queue: leave the
    # processing list alone).
    def self.finished(token : Int64) : Bool
      @@lock.synchronize do
        @@fibers.reject! { |_, t| t == token }
        @@jobs.delete(token).try(&.state.abandoned?) || false
      end
    end

    # Whether the job being executed by the current fiber was abandoned by shutdown. Read only; false for a fiber
    # that is not running a claimed job.
    def self.abandoned? : Bool
      @@lock.synchronize do
        token = @@fibers[Fiber.current.object_id]? || return false
        @@jobs[token]?.try(&.state.abandoned?) || false
      end
    end

    # Marks every claimed or running job abandoned and returns them as {queue, job}.
    def self.abandon_all : Array({String, String})
      @@lock.synchronize do
        abandoned = [] of {String, String}
        @@jobs.each do |token, entry|
          next if entry.state.abandoned?

          abandoned << {entry.queue, entry.job}
          @@jobs[token] = Entry.new(entry.queue, entry.job, State::Abandoned)
        end
        abandoned
      end
    end

    # Waits until no job is claimed or running, or `timeout` passes. True when the process went quiet.
    def self.wait(timeout : Time::Span) : Bool
      deadline = Time.instant + timeout
      while count > 0
        return false if Time.instant >= deadline
        sleep 10.milliseconds
      end
      true
    end

    # Specs only: forgets everything.
    def self.clear : Nil
      @@lock.synchronize do
        @@jobs.clear
        @@fibers.clear
      end
    end
  end
end
