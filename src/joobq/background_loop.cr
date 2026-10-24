module JoobQ
  # A cancellable periodic fiber.
  #
  # `stop` wakes a loop that is sleeping between iterations and waits for the
  # fiber to exit, so no iteration runs after `stop` has returned. Flag-only
  # stops are racy once fibers may run on other threads (Crystal's default
  # execution context is parallel).
  #
  # Every `start` owns its own run state, so a restart after a `stop` that
  # timed out can never leave two live fibers sharing one flag.
  class BackgroundLoop
    Log = ::Log.for("BACKGROUND_LOOP")

    ERROR_BACKOFF = 5.seconds

    private class Run
      getter active = Atomic(Bool).new(true)
      getter wake = Channel(Nil).new(1)
      getter done = Channel(Nil).new(1)
      property fiber : Fiber?
    end

    @lock = Sync::Mutex.new
    @run : Run?

    def initialize(@name : String, @error_backoff : Time::Span = ERROR_BACKOFF)
    end

    def running? : Bool
      @lock.synchronize { !@run.nil? }
    end

    # Starts the loop. The block runs one iteration and returns how long to
    # sleep before the next one. Returns false when already running.
    def start(&body : -> Time::Span) : Bool
      run = @lock.synchronize do
        next nil if @run
        @run = Run.new
      end
      return false unless run

      spawn(name: @name) do
        run.fiber = Fiber.current
        begin
          while run.active.get
            delay = begin
              body.call
            rescue ex
              Log.error &.emit("Iteration failed", loop: @name, error_class: ex.class.name, error: ex.message)
              @error_backoff
            end

            stopped = false
            select
            when run.wake.receive?
              stopped = true
            when timeout(delay)
            end
            break if stopped
          end
        ensure
          run.done.send(nil)
        end
      end
      true
    end

    # Stops the loop and waits (up to `wait`) for its fiber to exit. Returns
    # false when the loop was not running. When called from inside the loop
    # body itself it does not wait (a fiber cannot join itself).
    def stop(wait : Time::Span = 5.seconds) : Bool
      run = @lock.synchronize do
        current = @run
        @run = nil
        current
      end
      return false unless run

      run.active.set(false)
      run.wake.send(nil)
      return true if run.fiber == Fiber.current

      select
      when run.done.receive
      when timeout(wait)
        Log.warn &.emit("Loop did not stop in time", loop: @name)
      end
      true
    end
  end
end
