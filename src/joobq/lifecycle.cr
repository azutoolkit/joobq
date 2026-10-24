module JoobQ
  # How long `JoobQ.shutdown` waits, all steps together, before it gives up and returns.
  SHUTDOWN_TIMEOUT = 15.seconds

  # Time kept back at the end of the budget (at most half of it) for putting abandoned jobs back and flushing the
  # latency counters, so a stuck job that used up the wait does not leave those steps with nothing.
  SHUTDOWN_RESERVE = 1.second

  # The least a step that must run gets, whatever is left of the budget.
  SHUTDOWN_GRACE = 200.milliseconds

  # Exit status of `forge` after a clean shutdown, and after one that had to abandon jobs at the deadline.
  EXIT_CLEAN     = 0
  EXIT_ABANDONED = 3

  @@shutdown_lock = Sync::Mutex.new
  @@shut_down = Atomic(Bool).new(false)
  @@finished = Atomic(Bool).new(false)
  @@abandoned = Atomic(Int32).new(0)
  @@signal_lock = Sync::Mutex.new
  @@first_signal_at : Time::Instant? = nil

  # True once `shutdown` has begun.
  def self.shut_down? : Bool
    @@shut_down.get
  end

  # True once `shutdown` has finished.
  def self.shutdown_finished? : Bool
    @@finished.get
  end

  # How many jobs the shutdown had to give up on (returned to their queues) because they were still running at the
  # deadline. Zero after a clean shutdown.
  def self.abandoned_jobs : Int32
    @@abandoned.get
  end

  # Stops this process in order, within `timeout` in total:
  #
  # 1. the REST API started by `forge` (no new requests)
  # 2. every scheduler of the configuration, the delayed-job scheduler and the expired-job reaper (no new work)
  # 3. the workers of every queue (they claim nothing more)
  # 4. the jobs claimed or running, waited for until `timeout` minus `SHUTDOWN_RESERVE` (at most half of `timeout`)
  # 5. the jobs still not finished then: each is put back at the end of its queue in one atomic step
  #    (`RedisStore#requeue_from_processing`), jobs not yet started are never started, and `abandoned_jobs`
  #    counts them
  # 6. the latency counters (flushed to Redis)
  #
  # What a job does after it was put back: its execution may well go on (a fiber cannot be killed) and finish its
  # own side effects inside `perform` (a call to another system, a row written). What JoobQ itself does for it is
  # switched off: it is not retried, dead-lettered, counted as processed or failed, announced, or removed from the
  # processing list, so the requeued copy is the only one JoobQ schedules. Workers also claim nothing once the
  # shutdown has begun.
  #
  # Step 5 is the shutdown's own recovery: it does not rely on the start-up recovery of the next process
  # (`Queue#start` moves at most one job per queue back, and moves jobs of any process serving the queue). A job
  # put back this way runs again from the start, possibly in another process while this one winds down: jobs must
  # be safe to run twice, as they already must be after a crash. A job that crashes the process before step 5
  # (SIGKILL) is still left to the start-up recovery.
  #
  # Safe to call from any fiber, any number of times: the first call does the work and returns true, later calls
  # (also while the first is still running) wait for it and return false. After a shutdown the queues of this
  # process cannot be started again.
  def self.shutdown(timeout : Time::Span = SHUTDOWN_TIMEOUT) : Bool
    @@shutdown_lock.synchronize do
      return false if @@shut_down.get

      @@shut_down.set(true)
      deadline = Time.instant + timeout
      Log.info &.emit("JoobQ shutting down", timeout_seconds: timeout.total_seconds)

      step("api", deadline) { APIServer.stop }
      step("schedulers", deadline) { stop_schedulers }
      step("queues", deadline) { stop_queues(deadline) }

      reserve = {SHUTDOWN_RESERVE, timeout / 2}.min
      wait_for = {deadline - reserve - Time.instant, Time::Span.zero}.max
      unless InFlight.wait(wait_for)
        # the requeue gets the first half of the reserve, the latency flush the second; each at least a grace period
        requeue_deadline = {deadline - reserve / 2, Time.instant + SHUTDOWN_GRACE}.max
        step("requeue", requeue_deadline) { requeue_unfinished(requeue_deadline) }
      end
      step("latency", {deadline, Time.instant + SHUTDOWN_GRACE}.max) { Latency.stop }

      Log.info &.emit("JoobQ stopped", abandoned_jobs: abandoned_jobs)
      true
    ensure
      @@finished.set(true)
    end
  end

  # Puts every job that is still claimed or running back on its queue, atomically per job. Jobs that are settling
  # (applying the outcome of a failure) are given a moment to finish first; one still unfinished then is
  # abandoned as a last resort, with its retry or dead-letter side effects possibly applied already.
  private def self.requeue_unfinished(deadline : Time::Instant) : Nil
    requeue(InFlight.abandon_all)
    return if InFlight.wait({deadline - Time.instant, 500.milliseconds}.min.clamp(Time::Span.zero, 500.milliseconds))

    late = InFlight.abandon_all(settling: true)
    Log.warn &.emit("Jobs still settling a failure at the deadline were returned to their queues anyway; their retry or dead-letter side effects may have been applied", count: late.size) unless late.empty?
    requeue(late)
  end

  private def self.requeue(jobs : Array({String, String})) : Nil
    return if jobs.empty?

    # The exit status says "gave up on jobs": it counts the jobs abandoned, whatever the requeue then manages
    @@abandoned.add(jobs.size)
    Log.warn &.emit("Jobs still executing at the shutdown deadline; returning them to their queues", count: jobs.size)
    store = config.store
    return unless store.is_a?(RedisStore)

    put_back = store.requeue_many_from_processing(jobs)
    Log.warn &.emit("Abandoned jobs that were no longer in the processing list", count: jobs.size - put_back) if put_back < jobs.size
  rescue ex
    Log.error &.emit("Could not return abandoned jobs to their queues", error: ex.message)
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
    # two registries exist (the configuration's and the factory's); a queue may be in both
    list = (config.queues.values + queues.values).uniq!(&.object_id)
    done = Channel(Nil).new(list.size) # buffered: a queue that stops after the deadline must not block forever
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

  # False when the environment variable JOOBQ_TRAP_SIGNALS is `0`, `false` or `no`.
  def self.trap_signals_default? : Bool
    !{"0", "false", "no"}.includes?(ENV["JOOBQ_TRAP_SIGNALS"]?.try(&.downcase))
  end

  # SIGTERM, SIGINT and SIGHUP (`Process.on_terminate` covers all three): shut down, then exit with status 0, or
  # 3 when jobs had to be abandoned at the deadline. A second signal more than a second after the first (an
  # impatient operator; a duplicate sent by a process group or a wrapper arrives together with the first and is
  # ignored) exits at once with status 1.
  def self.trap_termination(timeout : Time::Span) : Nil
    Process.on_terminate do |reason|
      now = Time.instant
      first, since = @@signal_lock.synchronize do
        if (at = @@first_signal_at)
          {false, now - at}
        else
          @@first_signal_at = now
          {true, Time::Span.zero}
        end
      end

      if first
        Log.info &.emit("Termination requested", reason: reason.to_s)
        shutdown(timeout)
        exit(abandoned_jobs > 0 ? EXIT_ABANDONED : EXIT_CLEAN)
      elsif since > 1.second
        Log.warn { "Second termination signal, exiting without waiting" }
        exit 1
      end
    end
  end
end
