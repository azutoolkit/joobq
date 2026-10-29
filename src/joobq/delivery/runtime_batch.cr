module JoobQ::Delivery
  class Runtime
    def admit_many(queue : String, requests : Array(Tuple(String, String)), delay : Time::Span = Time::Span.zero, traceparent : String? = Fiber.current.joobq_traceparent) : Array(Admission)
      raise ArgumentError.new("runtime is draining/closed") if @closed.get
      raise ArgumentError.new("batch size must be 1..128") unless 1 <= requests.size <= Ledger::MAX_BATCH
      raise ArgumentError.new("batch payload limit exceeded") if requests.sum(0_i64) { |r| r[1].bytesize.to_i64 } > Ledger::MAX_BATCH_BYTES
      # Preserve per-job publish spans when telemetry is enabled.
      return requests.map { |id, payload| admit(queue, id, payload, delay, traceparent) } if @telemetry
      results = ledger(queue).admit_many(requests, delay, traceparent)
      results.each { |result| metrics.admission(result.code) }
      results
    end

    private struct BatchExecution
      getter active : ActiveLease
      property started : Time::Instant
      property span : Span? = nil
      property outcome : Outcome? = nil
      property failed : Bool = true

      def initialize(@active, @started)
      end
    end

    # Opt-in short-job mode: each fixed worker reserves a bounded group of slots,
    # executes its handlers sequentially and acknowledges their individual leases
    # together. Every claimed job (including those waiting locally) is renewed.
    # Slow/I/O-heavy handlers should use the default batch_size=1 concurrency.
    private def execute_many(registration : Registration, claims : Array(Claim), acquired : Time::Instant) : Nil
      work = claims.map do |claim|
        active = ActiveLease.new(Context.new(claim, acquired, lease, @execution_timeout), registration.ledger, acquired + lease / 3)
        BatchExecution.new(active, acquired)
      end
      @lock.synchronize { work.each { |entry| @active[entry.active.context.claim.token] = entry.active } }
      parent = Fiber.current.joobq_traceparent
      begin
        work.each_with_index do |entry, index|
          context = entry.active.context
          claim = context.claim
          entry.started = Time.instant
          entry.span = Span.new(claim.traceparent, registration.name, "process", claim.id) if @telemetry
          Fiber.current.joobq_traceparent = entry.span.try(&.traceparent) || claim.traceparent
          begin
            outcome = perform(registration, context)
            context.check!
            unless (outcome.state.completed? || outcome.state.dead? || outcome.state.scheduled?) && Time::Span.zero <= outcome.delay <= 365.days
              raise ArgumentError.new("handler returned an invalid delivery outcome")
            end
            entry.outcome = outcome
          rescue ex : LeaseLost
            metrics.increment("abandoned")
          rescue ex
            metrics.increment("execution_errors")
          ensure
            work[index] = entry
          end
        end
        # Renew all claims until every handler returns, including completed
        # handlers waiting for acknowledgment. Stop renewal under each lease lock.
        pending = Array(Tuple(Claim, State, Time::Span)).new(claims.size)
        indexes = Array(Int32).new(claims.size)
        work.each_with_index do |entry, index|
          next unless outcome = entry.outcome
          active = entry.active
          valid = active.lock.synchronize do
            active.finished.set(true)
            !active.context.cancelled?
          end
          if valid
            pending << {active.context.claim, outcome.state, outcome.delay}
            indexes << index
          else
            metrics.increment("abandoned")
          end
        end
        # Redis also checks each ownership token and deadline atomically.
        unless pending.empty?
          registration.ledger.settle_many(pending).each_with_index do |result, offset|
            metrics.settlement(result)
            index = indexes[offset]
            entry = work[index]
            entry.failed = !(result.applied? || result.already_applied?) || pending[offset][1].dead?
            work[index] = entry
          end
        end
      rescue ex
        metrics.increment("execution_errors")
      ensure
        work.each do |entry|
          entry.active.lock.synchronize { entry.active.finished.set(true) }
          if span = entry.span
            @telemetry.try { |sink| sink.publish(span.finish(entry.failed)) }
          end
          metrics.observe(Time.instant - entry.started)
        end
        Fiber.current.joobq_traceparent = parent
        @lock.synchronize { work.each { |entry| @active.delete(entry.active.context.claim.token) } }
      end
    end
  end
end
