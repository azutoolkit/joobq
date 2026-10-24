module JoobQ
  # Counts the jobs this process is executing right now, so `JoobQ.shutdown` can let them finish.
  module InFlight
    @@count = Atomic(Int32).new(0)

    def self.count : Int32
      @@count.get
    end

    def self.started : Nil
      @@count.add(1)
    end

    def self.finished : Nil
      @@count.sub(1)
    end

    # Waits until no job is executing, or `timeout` passes. True when the process went quiet.
    def self.wait(timeout : Time::Span) : Bool
      deadline = Time.instant + timeout
      while count > 0
        return false if Time.instant >= deadline
        sleep 10.milliseconds
      end
      true
    end
  end
end
