module JoobQ::Delivery
  class AdmissionFailed < Exception
    getter admission : Admission

    def initialize(@admission)
      super("delivery admission #{@admission.code}: #{@admission.reason}")
    end
  end

  class LeaseLost < Exception; end

  # Cooperative cancellation only: losing a lease never kills a Crystal fiber.
  class Context
    getter claim : Claim
    START = Time.instant
    @cancelled = Atomic(Bool).new(false)
    @valid_until = Atomic(Int64).new(Int64::MAX)
    @execution_deadline : Time::Instant

    def initialize(@claim, acquired : Time::Instant = Time.instant, lease : Time::Span = 30.seconds, execution_timeout : Time::Span = 5.minutes)
      @execution_deadline = acquired + execution_timeout
      extend_lease(acquired, lease)
    end

    def extend_lease(acquired : Time::Instant, lease : Time::Span) : Nil
      @valid_until.set(((acquired - START) + lease).total_nanoseconds.to_i64)
    end

    def cancelled? : Bool
      @cancelled.get || Time.instant >= @execution_deadline || (Time.instant - START).total_nanoseconds.to_i64 >= @valid_until.get
    end

    def cancel : Nil
      @cancelled.set(true)
    end

    def check! : Nil
      raise LeaseLost.new("delivery lease is no longer owned") if cancelled?
    end

    # Stable across redelivery; pass this to an external service's idempotency API.
    def idempotency_key : String
      claim.id
    end
  end

  record Outcome, state : State = State::Completed, delay : Time::Span = Time::Span.zero do
    def self.retry(delay : Time::Span) : self
      new(State::Scheduled, delay)
    end
  end

  record Drain, clean : Bool, active : Int32, elapsed : Time::Span

  # One runtime owns its registry, resource budget, supervision and telemetry.
  # Admission is explicit so legacy schedulers/middleware cannot acknowledge a
  # tokenless processing list in place of a leased record.
  class Runtime
    record Registration, name : String, ledger : Ledger, handler : Proc(String, Context, Outcome)

    getter store : RedisStore
    getter namespace : String
    getter capacity : Int32
    getter lease : Time::Span
    getter metrics = Metrics.new
    @registrations = {} of String => Registration
    @maintenance = [] of Proc(Nil)
    @lock = Sync::Mutex.new
    @running = Atomic(Bool).new(false)
    @closed = Atomic(Bool).new(false)
    @active = {} of String => Context
    @fibers = Atomic(Int32).new(0)
    @owner = UUID.random.to_s
    @next_queue = Atomic(Int32).new(0)
    @breaker = Circuit.new

    def initialize(@store : RedisStore, @namespace : String, @capacity : Int32 = 8,
                   @lease : Time::Span = 30.seconds, @poll : Time::Span = 20.milliseconds,
                   @repair_every : Time::Span = 1.second, @max_records : Int32 = 100_000,
                   @telemetry : Telemetry? = nil, @execution_timeout : Time::Span = 5.minutes, production : Bool = true)
      raise ArgumentError.new("capacity must be 1..1024") unless 1 <= capacity <= 1024
      raise ArgumentError.new("lease must be 100ms..24h") unless 100.milliseconds <= lease <= 24.hours
      raise ArgumentError.new("poll and repair intervals must be positive") unless @poll > Time::Span.zero && @repair_every > Time::Span.zero
      raise ArgumentError.new("execution timeout must be positive") unless @execution_timeout > Time::Span.zero
      Ledger.new(store.redis, namespace, "validation", max_records: @max_records)
      verify_durability! if production
    end

    def verify_durability! : Nil
      config = store.redis.command(["CONFIG", "GET", "appendonly", "appendfsync", "maxmemory-policy"]).as(Array)
      values = {} of String => String
      config.each_slice(2) { |pair| values[pair[0].as(String)] = pair[1].as(String) }
      unless values["appendonly"]? == "yes" && values["appendfsync"]? == "always" && values["maxmemory-policy"]? == "noeviction"
        raise ArgumentError.new("durable runtime requires appendonly=yes, appendfsync=always and maxmemory-policy=noeviction")
      end
    end

    def register(queue : String, &handler : String, Context -> Outcome) : Ledger
      @lock.synchronize do
        raise ArgumentError.new("register queues before starting the runtime") if @running.get || @closed.get
        raise ArgumentError.new("queue is already registered") if @registrations.has_key?(queue)
        ledger = Ledger.new(store.redis, namespace, queue, max_records: @max_records)
        @registrations[queue] = Registration.new(queue, ledger, handler)
        ledger
      end
    end

    # A registered typed job gets immutable retry accounting from claim.attempt.
    # Legacy retry/DLQ middleware is deliberately not invoked on leased jobs.
    def register(queue : String, type : T.class) : Ledger forall T
      register(queue) do |raw, context|
        begin
          job = Encryption.strict { T.from_json(raw) }
          job.queue = queue
          context.check!
          next Outcome.new(State::Dead) if job.expires <= Time.utc.to_unix_ms
          if job.responds_to?(:perform_with_context)
            job.perform_with_context(context)
          else
            job.perform
          end
          Outcome.new
        rescue ex : JSON::Error
          Outcome.new(State::Dead)
        rescue ex : LeaseLost
          raise ex
        rescue ex
          if job && context.claim.attempt <= job.max_retries
            Outcome.retry((2_i64 ** Math.min(context.claim.attempt, 10_i64)).seconds)
          else
            Outcome.new(State::Dead)
          end
        end
      end
    end

    def ledger(queue : String) : Ledger
      @lock.synchronize { @registrations[queue]?.try(&.ledger) } || raise ArgumentError.new("unregistered durable queue #{queue}")
    end

    def admit(queue : String, request_id : String, payload : String, delay : Time::Span = Time::Span.zero, traceparent : String? = Fiber.current.joobq_traceparent) : Admission
      raise ArgumentError.new("runtime is draining/closed") if @closed.get
      span = Span.new(traceparent, queue, "publish", request_id) if @telemetry
      result = ledger(queue).admit(request_id, payload, delay: delay, traceparent: span.try(&.traceparent) || traceparent)
      @telemetry.try { |sink| sink.publish(span.not_nil!.finish(!result.code.accepted?)) }
      metrics.increment("admission_#{result.code.to_s.downcase}")
      result
    end

    def enqueue(queue : String, job : Job, request_id : String = job.jid.to_s) : Admission
      job.queue = queue
      result = admit(queue, request_id, job.to_json)
      raise AdmissionFailed.new(result) unless result.code.accepted?
      result
    end

    # Durable outboxes add bounded reconciliation passes before start.
    def maintain(&block : -> Nil) : Nil
      @lock.synchronize do
        raise ArgumentError.new("register maintenance before start") if @running.get || @closed.get
        @maintenance << block
      end
    end

    def start : self
      @lock.synchronize do
        raise ArgumentError.new("a stopped runtime cannot restart; drain its active work before replacement") if @closed.get
        raise ArgumentError.new("register at least one queue") if @registrations.empty?
        return self if @running.swap(true)
        capacity.times do
          @fibers.add(1)
          spawn(name: "delivery-worker") { worker_loop }
        end
        @fibers.add(1)
        spawn(name: "delivery-repair") { repair_loop }
      end
      self
    end

    def prometheus : String
      output = metrics.prometheus
      output += "joobq_delivery_active #{active_count}\n"
      output += "joobq_delivery_capacity #{capacity}\n"
      if telemetry = @telemetry
        output += "joobq_delivery_telemetry_dropped_total #{telemetry.dropped.get}\n"
        output += "joobq_delivery_telemetry_failures_total #{telemetry.failures.get}\n"
      end
      @lock.synchronize { @registrations.values }.each do |entry|
        # Registered names use the ledger's restricted alphabet.
        output += "joobq_delivery_pending{queue=\"#{entry.name}\"} #{store.redis.zcard(entry.ledger.ready_key)}\n"
        output += "joobq_delivery_leased{queue=\"#{entry.name}\"} #{store.redis.zcard(entry.ledger.leases_key)}\n"
        output += "joobq_delivery_quarantined{queue=\"#{entry.name}\"} #{store.redis.hlen(entry.ledger.quarantine_key)}\n"
      end
      output
    end

    def active_count : Int32
      @lock.synchronize { @active.size }
    end

    def running? : Bool
      @running.get
    end

    # Stops ingress and claiming. At timeout, active contexts are cancelled.
    # An already in-flight operation may finish, but token fencing prevents it
    # from changing a successor's lease. Unsettled records remain recoverable.
    # Active execution retains its worker slot until its actual fiber exits.
    def stop(timeout : Time::Span = 15.seconds) : Drain
      raise ArgumentError.new("shutdown timeout must not be negative") if timeout < Time::Span.zero
      started = Time.instant
      @closed.set(true)
      @running.set(false)
      deadline = started + timeout
      until @fibers.get == 0 || Time.instant >= deadline
        sleep Math.min(5.milliseconds, deadline - Time.instant).clamp(Time::Span.zero, 5.milliseconds)
      end
      @lock.synchronize { @active.each_value(&.cancel) }
      telemetry_stopped = @telemetry.try(&.stop(Math.max(deadline - Time.instant, Time::Span.zero))) != false
      Drain.new(@fibers.get == 0 && telemetry_stopped, active_count, Time.instant - started)
    end

    def serve(timeout : Time::Span = 15.seconds) : Drain
      signals = Channel(Nil).new(1)
      [Signal::INT, Signal::TERM].each do |signal|
        signal.trap do
          select
          when signals.send(nil)
          else
          end
        end
      end
      start
      signals.receive
      stop(timeout)
    ensure
      Signal::INT.reset
      Signal::TERM.reset
    end

    private def worker_loop : Nil
      registrations = @lock.synchronize { @registrations.values }
      while @running.get
        unless @breaker.allow?
          sleep @poll
          next
        end
        begin
          index = @next_queue.add(1).to_u32 % registrations.size.to_u32
          registration = registrations[index]
          acquired = Time.instant
          if claim = registration.ledger.claim(@owner, lease)
            @breaker.success
            execute(registration, claim, acquired)
          else
            @breaker.success
            sleep @poll
          end
        rescue ex
          metrics.increment("worker_errors")
          @breaker.failure
          Log.warn &.emit("Durable worker operation failed", namespace: namespace, error_class: ex.class.name)
          sleep @poll
        end
      end
    ensure
      @fibers.sub(1)
    end

    private def execute(registration : Registration, claim : Claim, acquired : Time::Instant) : Nil
      context = Context.new(claim, acquired, lease, @execution_timeout)
      @lock.synchronize { @active[claim.token] = context }
      finished = Channel(Nil).new(1)
      renewal_done = Channel(Nil).new(1)
      spawn do
        loop do
          select
          when finished.receive
            break
          when timeout(lease / 3)
            break if context.cancelled?
            renewal_started = Time.instant
            unless registration.ledger.renew(claim, lease).applied?
              metrics.increment("lease_lost")
              context.cancel
              break
            end
            context.extend_lease(renewal_started, lease)
          end
        end
      rescue
        context.cancel
        metrics.increment("renewal_errors")
      ensure
        renewal_done.send(nil)
      end
      started = Time.instant
      renewal_stopped = false
      parent = Fiber.current.joobq_traceparent
      span = Span.new(claim.traceparent, registration.name, "process", claim.id) if @telemetry
      Fiber.current.joobq_traceparent = span.try(&.traceparent) || claim.traceparent
      failed = true
      begin
        # A claim arriving after drain began is not executed or renewed forever.
        context.cancel unless @running.get
        context.check!
        outcome = begin
          registration.handler.call(claim.payload, context)
        rescue ex : LeaseLost
          raise ex
        rescue ex
          metrics.increment("handler_errors")
          Outcome.new(State::Dead)
        end
        finished.send(nil)
        renewal_done.receive
        renewal_stopped = true
        context.check!
        result = registration.ledger.settle(claim, outcome.state, outcome.delay)
        metrics.increment("settlement_#{result.to_s.downcase}")
        failed = !(result.applied? || result.already_applied?) || outcome.state.dead?
      rescue ex : LeaseLost
        metrics.increment("abandoned")
      rescue ex
        # Infrastructure failures leave the claim recoverable. Do not turn an
        # unknown completion into a different terminal outcome.
        metrics.increment("execution_errors")
      ensure
        @telemetry.try { |sink| sink.publish(span.not_nil!.finish(failed)) }
        Fiber.current.joobq_traceparent = parent
        metrics.observe(Time.instant - started)
        finished.send(nil) unless renewal_stopped
        # Do not release the execution slot while renewal still uses its claim.
        renewal_done.receive unless renewal_stopped
        @lock.synchronize { @active.delete(claim.token) }
      end
    end

    private def repair_loop : Nil
      registrations, maintenance = @lock.synchronize { {@registrations.values, @maintenance.dup} }
      cursors = Array(String).new(registrations.size, "0")
      while @running.get
        registrations.each_with_index do |registration, index|
          break unless @running.get
          begin
            cursors[index] = registration.ledger.repair(cursors[index])
          rescue ex
            metrics.increment("repair_errors")
            Log.warn &.emit("Durable repair failed", namespace: namespace, error_class: ex.class.name)
          end
        end
        maintenance.each do |pass|
          break unless @running.get
          begin
            pass.call
          rescue ex
            metrics.increment("outbox_errors")
            Log.warn &.emit("Durable outbox failed", namespace: namespace, error_class: ex.class.name)
          end
        end
        deadline = Time.instant + @repair_every
        while @running.get && Time.instant < deadline
          sleep Math.min(@poll, @repair_every)
        end
      end
    ensure
      @fibers.sub(1)
    end
  end

  class Circuit
    @lock = Sync::Mutex.new
    @failures = 0
    @until : Time::Instant = Time.instant
    @probe = false

    def allow? : Bool
      @lock.synchronize do
        return true if @failures < 5
        return false if Time.instant < @until || @probe
        @probe = true
        true
      end
    end

    def success : Nil
      @lock.synchronize { @failures = 0; @probe = false }
    end

    def failure : Nil
      @lock.synchronize do
        @failures += 1
        @probe = false
        @until = Time.instant + (200 + Random.rand(200)).milliseconds
      end
    end
  end

  class Metrics
    @lock = Sync::Mutex.new
    @counters = {} of String => Int64
    @seconds = 0.0
    @executions = 0_i64

    def increment(name : String) : Nil
      @lock.synchronize { @counters[name] = @counters.fetch(name, 0_i64) + 1 }
    end

    def observe(elapsed : Time::Span) : Nil
      @lock.synchronize { @seconds += elapsed.total_seconds; @executions += 1 }
    end

    # Fixed internal event names only; job/request IDs never become labels.
    def prometheus : String
      @lock.synchronize do
        String.build do |io|
          @counters.to_a.sort_by(&.[0]).each { |name, value| io << "joobq_delivery_" << name << "_total " << value << '\n' }
          io << "joobq_delivery_execution_seconds_sum " << @seconds << '\n'
          io << "joobq_delivery_execution_seconds_count " << @executions << '\n'
        end
      end
    end
  end
end
