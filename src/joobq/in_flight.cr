module JoobQ
  # The jobs this process has claimed and not finished, with the queue each came from, so `JoobQ.shutdown` can
  # let them finish and, at its deadline, put the rest back on their queues.
  #
  # A job is `claimed` from the moment its worker got it from Redis (before any fiber exists for it), `running`
  # once its fiber began, and `abandoned` when shutdown gave up on it and returned it to its queue: an abandoned
  # job's fiber must not start it (if it has not yet) and must not touch its processing entry when it ends (another
  # process may have claimed the same job since).
  module InFlight
    enum State
      Claimed
      Running
      Abandoned
    end

    record Entry, queue : String, state : State

    @@jobs = {} of String => Entry
    @@lock = Sync::Mutex.new

    # Jobs claimed or running (abandoned ones are not counted).
    def self.count : Int32
      @@lock.synchronize { @@jobs.count { |_, entry| !entry.state.abandoned? } }
    end

    # Registers freshly claimed jobs. Call it as soon as the claim returns.
    def self.claimed(queue : String, jobs : Array(String)) : Nil
      @@lock.synchronize { jobs.each { |job| @@jobs[job] = Entry.new(queue, State::Claimed) } }
    end

    # The job's fiber begins. False when shutdown abandoned the job first: do not run it.
    def self.begin_run(job : String) : Bool
      @@lock.synchronize do
        entry = @@jobs[job]?
        return false if entry.nil? || entry.state.abandoned?

        @@jobs[job] = Entry.new(entry.queue, State::Running)
        true
      end
    end

    # The job's fiber ends. True when shutdown had abandoned it (it is already back on its queue: leave the
    # processing list alone).
    def self.finished(job : String) : Bool
      @@lock.synchronize { @@jobs.delete(job).try(&.state.abandoned?) || false }
    end

    # Marks every claimed or running job abandoned and returns them as {queue, job}.
    def self.abandon_all : Array({String, String})
      @@lock.synchronize do
        abandoned = [] of {String, String}
        @@jobs.each do |job, entry|
          next if entry.state.abandoned?

          abandoned << {entry.queue, job}
          @@jobs[job] = Entry.new(entry.queue, State::Abandoned)
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
      @@lock.synchronize { @@jobs.clear }
    end
  end
end
