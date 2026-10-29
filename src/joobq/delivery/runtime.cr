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
    getter batch_size : Int32
    getter metrics = Metrics.new
    @registrations = {} of String => Registration
    @maintenance = [] of Proc(Nil)
    @lock = Sync::Mutex.new
    @running = Atomic(Bool).new(false)
    @closed = Atomic(Bool).new(false)

    # Only jobs which reach their renewal time spawn a renewal operation. A
    # shared scanner avoids two channels and a fiber allocation per short job.
    class ActiveLease
      getter context : Context
      getter ledger : Ledger
      getter lock = Sync::Mutex.new
      getter renewing = Atomic(Bool).new(false)
      getter finished = Atomic(Bool).new(false)
      @next_renewal = Atomic(Int64).new(0_i64)

      def initialize(@context, @ledger, next_renewal : Time::Instant)
        reschedule(next_renewal)
      end

      def reschedule(at : Time::Instant) : Nil
        @next_renewal.set((at - Context::START).total_nanoseconds.to_i64)
      end

      def due?(now : Time::Instant) : Bool
        !finished.get && (now - Context::START).total_nanoseconds.to_i64 >= @next_renewal.get
      end
    end

    @active = {} of String => ActiveLease
    @fibers = Atomic(Int32).new(0)
    @owner = UUID.random.to_s
    @next_queue = Atomic(UInt64).new(0_u64)
    @breaker = Circuit.new

    def initialize(@store : RedisStore, @namespace : String, @capacity : Int32 = 8,
                   @lease : Time::Span = 30.seconds, @poll : Time::Span = 20.milliseconds,
                   @repair_every : Time::Span = 1.second, @max_records : Int32 = 100_000,
                   @optimized_delivery : Bool = true, @telemetry : Telemetry? = nil, @execution_timeout : Time::Span = 5.minutes, production : Bool = true, @batch_size : Int32 = 1)
      raise ArgumentError.new("capacity must be 1..1024") unless 1 <= capacity <= 1024
      raise ArgumentError.new("batch size must be 1..128 and at most capacity") unless 1 <= batch_size <= Math.min(capacity, Ledger::MAX_BATCH)
      raise ArgumentError.new("lease must be 100ms..24h") unless 100.milliseconds <= lease <= 24.hours
      raise ArgumentError.new("poll and repair intervals must be positive") unless @poll > Time::Span.zero && @repair_every > Time::Span.zero
      raise ArgumentError.new("execution timeout must be positive") unless @execution_timeout > Time::Span.zero
      Ledger.new(store.redis, namespace, "validation", max_records: @max_records, optimized: @optimized_delivery)
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
        ledger = Ledger.new(store.redis, namespace, queue, max_records: @max_records, optimized: @optimized_delivery)
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
      metrics.admission(result.code)
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
        remaining = capacity
        while remaining > 0
          slots = Math.min(batch_size, remaining)
          @fibers.add(1)
          spawn worker_loop(slots), name: "delivery-worker"
          remaining -= slots
        end
        @fibers.add(1)
        spawn(name: "delivery-repair") { repair_loop }
        @fibers.add(1)
        spawn(name: "delivery-renewals") { renewal_loop }
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
      @lock.synchronize { @active.each_value { |entry| entry.context.cancel } }
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

    private def worker_loop(slots : Int32 = 1) : Nil
      registrations = @lock.synchronize { @registrations.values }
      while @running.get
        unless @breaker.allow?
          sleep @poll
          next
        end
        begin
          index = (@next_queue.add(1_u64) % registrations.size.to_u64).to_i
          registration = registrations[index]
          acquired = Time.instant
          if slots > 1
            claims = registration.ledger.claim_many(@owner, slots, lease)
            @breaker.success
            if claims.empty?
              sleep @poll
            else
              execute_many(registration, claims, acquired)
            end
          elsif claim = registration.ledger.claim(@owner, lease)
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

    private def perform(registration : Registration, context : Context) : Outcome
      context.cancel unless @running.get
      context.check!
      registration.handler.call(context.claim.payload, context)
    rescue ex : LeaseLost
      raise ex
    rescue ex
      metrics.increment("handler_errors")
      Outcome.new(State::Dead)
    end

    private def execute(registration : Registration, claim : Claim, acquired : Time::Instant) : Nil
      context = Context.new(claim, acquired, lease, @execution_timeout)
      active = ActiveLease.new(context, registration.ledger, acquired + lease / 3)
      @lock.synchronize { @active[claim.token] = active }
      started = Time.instant
      parent = Fiber.current.joobq_traceparent
      span = Span.new(claim.traceparent, registration.name, "process", claim.id) if @telemetry
      Fiber.current.joobq_traceparent = span.try(&.traceparent) || claim.traceparent
      failed = true
      begin
        outcome = perform(registration, context)
        # Serialize renewal/settlement for this lease only. Never hold the
        # registry mutex over Redis I/O, nor release a slot while renewal uses it.
        active.lock.synchronize do
          active.finished.set(true)
          context.check!
          result = registration.ledger.settle(claim, outcome.state, outcome.delay)
          metrics.settlement(result)
          failed = !(result.applied? || result.already_applied?) || outcome.state.dead?
        end
      rescue ex : LeaseLost
        metrics.increment("abandoned")
      rescue ex
        metrics.increment("execution_errors")
      ensure
        active.lock.synchronize { active.finished.set(true) }
        @telemetry.try { |sink| sink.publish(span.not_nil!.finish(failed)) }
        Fiber.current.joobq_traceparent = parent
        metrics.observe(Time.instant - started)
        @lock.synchronize { @active.delete(claim.token) }
      end
    end

    private def renewal_loop : Nil
      # Owned only by this scanner; entries themselves retain independent lease
      # lifetimes when a renewal fiber captures one. Never recycle a Context.
      entries = Array(ActiveLease).new(capacity)
      loop do
        entries.clear
        @lock.synchronize { @active.each_value { |entry| entries << entry } }
        break unless @running.get || entries.any? { |entry| !entry.context.cancelled? }
        now = Time.instant
        entries.each do |entry|
          next if entry.context.cancelled? || !entry.due?(now) || entry.renewing.swap(true)
          @fibers.add(1)
          spawn renew_entry(entry), name: "delivery-renew"
        end
        sleep Math.min(lease / 6, 20.milliseconds)
      end
    ensure
      @fibers.sub(1)
    end

    private def renew_entry(entry : ActiveLease) : Nil
      begin
        entry.lock.synchronize do
          unless entry.finished.get || entry.context.cancelled?
            before = Time.instant
            if entry.ledger.renew(entry.context.claim, lease).applied?
              entry.context.extend_lease(before, lease)
              entry.reschedule(before + lease / 3)
            else
              entry.context.cancel
              metrics.increment("lease_lost")
            end
          end
        end
      rescue
        entry.context.cancel
        metrics.increment("renewal_errors")
      ensure
        entry.renewing.set(false)
        @fibers.sub(1)
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

    def admission(code : AdmissionCode) : Nil
      case code
      in AdmissionCode::Accepted then increment("admission_accepted")
      in AdmissionCode::Rejected then increment("admission_rejected")
      in AdmissionCode::Unknown  then increment("admission_unknown")
      end
    end

    def settlement(result : Settlement) : Nil
      case result
      in Settlement::Applied        then increment("settlement_applied")
      in Settlement::AlreadyApplied then increment("settlement_alreadyapplied")
      in Settlement::Stale          then increment("settlement_stale")
      in Settlement::Unknown        then increment("settlement_unknown")
      end
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
