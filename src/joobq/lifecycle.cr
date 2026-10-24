module JoobQ
  # How long `JoobQ.shutdown` waits, all steps together, before it gives up and returns.
  SHUTDOWN_TIMEOUT = 15.seconds

  @@shutdown_lock = Sync::Mutex.new
  @@shut_down = Atomic(Bool).new(false)
  @@finished = Atomic(Bool).new(false)
  @@first_signal_at = Atomic(Int64).new(0_i64)

  # True once `shutdown` has begun.
  def self.shut_down? : Bool
    @@shut_down.get
  end

  # True once `shutdown` has finished (what `forge` waits for before it returns).
  def self.shutdown_finished? : Bool
    @@finished.get
  end

  # Stops this process in order, within `timeout` in total:
  #
  # 1. the REST API started by `forge` (no new requests)
  # 2. every scheduler of the configuration, the delayed-job scheduler and the expired-job reaper (no new work)
  # 3. the workers of every queue (they claim nothing more)
  # 4. the jobs still executing (waited for, up to what is left of `timeout`)
  # 5. the latency counters (flushed to Redis)
  #
  # A job that does not finish in time stays in Redis' processing list and is re-queued at the next start
  # (`Queue#start` does that), so it runs again: jobs must be safe to run twice, as they already must be after
  # a crash. Safe to call from any fiber, any number of times: the first call does the work and returns true,
  # later calls (also while the first is still running) wait for it and return false. After a shutdown the
  # queues of this process cannot be started again.
  def self.shutdown(timeout : Time::Span = SHUTDOWN_TIMEOUT) : Bool
    @@shutdown_lock.synchronize do
      return false if @@shut_down.get

      @@shut_down.set(true)
      deadline = Time.instant + timeout
      Log.info &.emit("JoobQ shutting down", timeout_seconds: timeout.total_seconds)

      step("api", deadline) { APIServer.stop }
      step("schedulers", deadline) { stop_schedulers }
      step("queues", deadline) { stop_queues(deadline) }

      remaining = {deadline - Time.instant, Time::Span.zero}.max
      unless InFlight.wait(remaining)
        Log.warn &.emit("Jobs still executing at shutdown; they will be re-queued at the next start", count: InFlight.count)
      end
      step("latency", deadline) { Latency.stop }

      Log.info { "JoobQ stopped" }
      true
    ensure
      @@finished.set(true)
    end
  end

  # The cron, recurring and delayed loops of every scheduler, the delayed-job scheduler and the reaper.
  private def self.stop_schedulers : Nil
    config.schedulers.each(&.stop)
    RecurringJobScheduler.instance.stop
    config.delayed_job_scheduler.stop
    config.expired_job_reaper.stop
  end

  # Stops the workers of all queues at the same time, so the wait is that of the slowest queue, not their sum.
  private def self.stop_queues(deadline : Time::Instant) : Nil
    done = Channel(Nil).new
    # two registries exist (the configuration's and the factory's); a queue may be in both
    list = (config.queues.values + queues.values).uniq!(&.object_id)
    list.each do |queue|
      spawn do
        queue.stop!
      rescue ex
        Log.error &.emit("Queue did not stop cleanly", queue: queue.name, error: ex.message)
      ensure
        done.send(nil)
      end
    end
    list.each do
      select
      when done.receive
      when timeout({deadline - Time.instant, Time::Span.zero}.max)
        Log.warn { "Some queues did not stop in time" }
        break
      end
    end
  end

  # Runs one shutdown step in its own fiber so a stuck step costs at most the time that is left.
  private def self.step(name : String, deadline : Time::Instant, &block : ->) : Nil
    finished = Channel(Nil).new(1)
    spawn do
      block.call
    rescue ex
      Log.error &.emit("Shutdown step failed", step: name, error: ex.message)
    ensure
      finished.send(nil)
    end

    select
    when finished.receive
    when timeout({deadline - Time.instant, Time::Span.zero}.max)
      Log.warn &.emit("Shutdown step timed out", step: name)
    end
  end

  # :nodoc:
  def self.trap_signals_default? : Bool
    !{"0", "false", "no"}.includes?(ENV["JOOBQ_TRAP_SIGNALS"]?.try(&.downcase))
  end

  # SIGTERM / SIGINT: shut down, then exit 0. A second signal more than a second after the first (an impatient
  # operator; a duplicate sent by a process group or a wrapper arrives together with the first and is ignored)
  # exits at once with status 1.
  def self.trap_termination(timeout : Time::Span) : Nil
    Process.on_terminate do |reason|
      first = @@first_signal_at.compare_and_set(0_i64, Time.utc.to_unix_ms).last
      if first
        Log.info &.emit("Termination requested", reason: reason.to_s)
        shutdown(timeout)
        exit 0
      elsif Time.utc.to_unix_ms - @@first_signal_at.get > 1000
        Log.warn { "Second termination signal, exiting without waiting" }
        exit 1
      end
    end
  end
end
