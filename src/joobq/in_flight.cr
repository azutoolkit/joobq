module JoobQ
  # The jobs this process has claimed and not finished, with the queue each came from, so `JoobQ.shutdown` can
  # let them finish and, at its deadline, put the rest back on their queues.
  #
  # A claim is identified by a token, not by the job's raw string (two claims of the same string must not
  # collide). It is `claimed` from the moment its worker got the job from Redis (before any fiber exists for it),
  # `running` once its fiber began, `settling` while the fiber applies the outcome of a failure (scheduling a retry,
  # dead-lettering) and `abandoned` when shutdown gave up on it and returned it to its queue.
  #
  # An abandoned execution must be inert: its fiber must not start the job (if it has not yet), must not touch the
  # processing list when it ends (another process may have claimed the job since), and none of its failure or
  # success handling may schedule, dead-letter, count or announce anything, because the requeued copy owns the
  # job now. The handling asks `settle` before its first side effect: the answer and the move to `settling` are
  # one step under the lock, so shutdown either abandoned the job before (the handling does nothing) or finds it
  # settling and waits for it instead of requeuing it while a retry is being scheduled.
  #
  # When the fiber ends, the claim is `finishing` while the worker cleans up (removes the copy from the processing
  # list, counts the job): it still counts as in flight, so shutdown waits for the cleanup. `done` then forgets the
  # claim, or, when Redis refused the cleanup (it was away), keeps it as `retained` under the same token: nothing
  # runs for it any more, but its copy is still in this process's own processing list. The owner re-drives it
  # (`RedisStore#redrive_retained`, oldest claim first); `abandon_all` leaves retained claims alone, and shutdown
  # drains them in a step of their own that counts what it really put back.
  module InFlight
    enum State
      Claimed
      Running
      Settling
      Abandoned
      Finishing
      Retained
    end

    record Entry, queue : String, job : String, state : State, fiber : UInt64? = nil

    @@jobs = {} of Int64 => Entry
    @@fibers = {} of UInt64 => Int64
    @@next = 0_i64
    @@lock = Sync::Mutex.new
    # Set for good once any job was abandoned: until then `abandoned?` is a single atomic read.
    @@any_abandoned = Atomic(Bool).new(false)

    # Specs only: called, outside the lock, right after a fiber moved to `settling`.
    class_property after_settle : Proc(Nil)? = nil

    # Jobs claimed, running, settling or finishing (cleaning up after the fiber ended); abandoned and retained ones are not counted.
    def self.count : Int32
      @@lock.synchronize { @@jobs.count { |_, entry| active?(entry) } }
    end

    # True while this process has a claim of *queue* that is claimed, running, settling or finishing (abandoned and retained ones do not count).
    def self.any?(queue : String) : Bool
      @@lock.synchronize { @@jobs.any? { |_, entry| entry.queue == queue && active?(entry) } }
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

    # The claim's fiber begins (the current fiber is remembered for `settle` and `abandoned?`). False when
    # shutdown abandoned the claim first: do not run the job.
    def self.begin_run(token : Int64) : Bool
      @@lock.synchronize do
        entry = @@jobs[token]?
        return false if entry.nil? || entry.state.abandoned?

        fiber = Fiber.current.object_id
        @@jobs[token] = Entry.new(entry.queue, entry.job, State::Running, fiber)
        @@fibers[fiber] = token
        true
      end
    end

    # The claim's fiber ends and its cleanup begins (the claim stays counted, as `finishing`, until `done`). True
    # when shutdown had abandoned it (the job is already back on its queue: leave the processing list alone, and do
    # not call `done`).
    def self.finishing(token : Int64) : Bool
      @@lock.synchronize do
        entry = @@jobs[token]?
        next true unless entry

        entry.fiber.try { |fiber| @@fibers.delete(fiber) if @@fibers[fiber]? == token }
        next !@@jobs.delete(token).nil? if entry.state.abandoned?

        @@jobs[token] = Entry.new(entry.queue, entry.job, State::Finishing)
        false
      end
    end

    # The cleanup of a `finishing` claim is over: the claim is forgotten, or with `retain` (Redis refused the
    # cleanup, so the copy is still in the processing list) it becomes `retained`, in the same step. A claim that
    # shutdown abandoned meanwhile (the last resort) is forgotten either way: the requeued copy owns the job.
    def self.done(token : Int64, retain : Bool) : Nil
      @@lock.synchronize do
        entry = @@jobs[token]?
        next unless entry

        if retain && entry.state.finishing?
          @@jobs[token] = Entry.new(entry.queue, entry.job, State::Retained)
        else
          @@jobs.delete(token)
        end
      end
    end

    # The claim's fiber ends, with nothing to clean up. True when shutdown had abandoned it (the job is already back
    # on its queue: leave the processing list alone).
    def self.finished(token : Int64) : Bool
      @@lock.synchronize do
        entry = @@jobs.delete(token)
        entry.try(&.fiber).try { |fiber| @@fibers.delete(fiber) if @@fibers[fiber]? == token }
        entry.try(&.state.abandoned?) || false
      end
    end

    # The retained copies as {token, queue, job}, oldest claim first (by token, the order they were claimed in).
    def self.retained : Array({Int64, String, String})
      @@lock.synchronize do
        @@jobs.compact_map { |token, entry| {token, entry.queue, entry.job} if entry.state.retained? }.sort_by(&.first)
      end
    end

    # Forgets a retained copy once it was put back (or found gone). False when it was not retained any more.
    def self.release(token : Int64) : Bool
      @@lock.synchronize do
        next false unless @@jobs[token]?.try(&.state.retained?)

        @@jobs.delete(token)
        true
      end
    end

    # Called by the failure handling of the current fiber's job before its first side effect. True: go ahead (the
    # job is now `settling`, shutdown waits for it rather than abandoning it). False: shutdown abandoned this
    # execution, so do nothing. True as well for a fiber that is not running a claimed job.
    def self.settle : Bool
      allowed = @@lock.synchronize do
        token = @@fibers[Fiber.current.object_id]? || next true
        entry = @@jobs[token]? || next true
        next false if entry.state.abandoned?

        @@jobs[token] = Entry.new(entry.queue, entry.job, State::Settling, entry.fiber)
        true
      end
      after_settle.try(&.call) if allowed
      allowed
    end

    # The raw copy the current fiber's claim holds in this process's processing list, while the job runs or applies a
    # failure outcome; nil for a fiber that is not running a claimed job (a caller outside a worker, or a worker
    # already cleaning up). The store fences the failure outcome on it (see `RedisStore#settle_claim`).
    def self.current_job : String?
      @@lock.synchronize do
        token = @@fibers[Fiber.current.object_id]? || next nil
        entry = @@jobs[token]? || next nil
        entry.job if entry.state.running? || entry.state.settling?
      end
    end

    # The current fiber's claim was reclaimed by another process (its copy is gone from this process's processing
    # list): the execution becomes inert, like one abandoned at shutdown, because the process that reclaimed the job
    # owns it now. Nothing of it is scheduled, counted or removed afterwards.
    def self.fence : Nil
      @@lock.synchronize do
        token = @@fibers[Fiber.current.object_id]? || next
        entry = @@jobs[token]? || next
        next if entry.state.retained?

        @@jobs[token] = Entry.new(entry.queue, entry.job, State::Abandoned, entry.fiber)
        @@any_abandoned.set(true)
      end
    end

    # Whether the job being executed by the current fiber was abandoned by shutdown. Read only, and cheap enough
    # for the hot path: false without taking a lock until some job has been abandoned.
    def self.abandoned? : Bool
      return false unless @@any_abandoned.get

      @@lock.synchronize do
        token = @@fibers[Fiber.current.object_id]? || return false
        @@jobs[token]?.try(&.state.abandoned?) || false
      end
    end

    # Marks the claimed and running jobs abandoned and returns them as {queue, job}. Jobs that are settling are
    # left alone (they are applying a failure outcome and finish in a moment), unless `settling` is true: the last
    # resort at the deadline, when their side effects may already be done.
    def self.abandon_all(settling : Bool = false) : Array({String, String})
      @@lock.synchronize do
        abandoned = [] of {String, String}
        @@jobs.each do |token, entry|
          next if entry.state.abandoned? || entry.state.retained?
          next if (entry.state.settling? || entry.state.finishing?) && !settling

          abandoned << {entry.queue, entry.job}
          @@jobs[token] = Entry.new(entry.queue, entry.job, State::Abandoned, entry.fiber)
        end
        @@any_abandoned.set(true) unless abandoned.empty?
        abandoned
      end
    end

    # Waits until no job is claimed, running, settling or finishing, or `timeout` passes. True when the process went quiet.
    def self.wait(timeout : Time::Span) : Bool
      deadline = Time.instant + timeout
      while count > 0
        return false if Time.instant >= deadline
        sleep 10.milliseconds
      end
      true
    end

    # Claimed, running, settling or finishing: still the work of a fiber of this process
    private def self.active?(entry : Entry) : Bool
      !entry.state.abandoned? && !entry.state.retained?
    end

    # Specs only: forgets everything.
    def self.clear : Nil
      @@lock.synchronize do
        @@jobs.clear
        @@fibers.clear
        @@any_abandoned.set(false)
      end
      self.after_settle = nil
    end
  end
end
