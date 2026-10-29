module JoobQ::Delivery
  class Ledger
    MAX_BATCH       = 128
    MAX_BATCH_BYTES = 2 * 1024 * 1024

    # Bounded transport batches, not all-or-nothing transactions. An interrupted
    # script may have persisted any prefix; callers reconcile each stable ID.
    def admit_many(requests : Array(Tuple(String, String)), delay : Time::Span = Time::Span.zero, traceparent : String? = nil) : Array(Admission)
      validate_batch_size(requests.size)
      TraceParent.parse(traceparent)
      raise ArgumentError.new("admission delay must be 0..365 days") unless Time::Span.zero <= delay <= 365.days
      ids = requests.map { |request| identity(request[0]) }
      validate_batch_bytes(requests.sum(0_i64) { |request| request[1].bytesize.to_i64 })
      return requests.map { |request| admit(request[0], request[1], delay, traceparent) } unless @optimized
      args = Array(String).new(2 + requests.size * 2)
      args << delay.total_milliseconds.to_i64.to_s << @record_limit
      submitted = Array(Tuple(Int32, Record)).new(requests.size)
      results = ids.map { |id| Admission.new(AdmissionCode::Rejected, id, reason: "payload size is outside the configured limit") }
      requests.each_with_index do |request, index|
        payload = request[1]
        next unless 1 <= payload.bytesize <= @max_payload_bytes
        entry = Record.new(ids[index], payload, Checksum.hex(payload))
        entry.traceparent = traceparent
        entry.state = State::Scheduled if delay > Time::Span.zero
        args << entry.id << entry.encoded
        submitted << {index, entry}
      end
      return results if submitted.empty?
      begin
        values = Scripts::ADMIT_MANY.call(@redis, keys, args).as(Array)
      rescue Redis::Error
        submitted.each { |i, _entry| results[i] = Admission.new(AdmissionCode::Unknown, ids[i], reason: "batch outcome unknown; resolve each request ID") }
        return results
      end
      submitted.each_with_index do |(index, entry), offset|
        value = values[offset].as(Array)
        results[index] = case value[0].as(Int64)
                         when 3
                           entry.due_at = value[1].as(Int64)
                           Admission.new(AdmissionCode::Accepted, ids[index], entry)
                         when 1
                           admission_for(decode(ids[index], value[1].as(String)), ids[index], requests[index][1])
                         when -1
                           Admission.new(AdmissionCode::Rejected, ids[index], reason: "retained record capacity reached")
                         else
                           admit(requests[index][0], requests[index][1], delay, traceparent)
                         end
      end
      results
    end

    def claim_many(owner : String, limit : Int32, lease : Time::Span = 30.seconds) : Array(Claim)
      validate_batch_size(limit)
      raise ArgumentError.new("owner must not be empty") if owner.empty?
      duration = positive_ms(lease)
      unless @optimized
        value = claim(owner, lease)
        return value ? [value] : [] of Claim
      end
      values = Scripts::CLAIM_MANY.call(@redis, keys, [owner, UUID.random.to_s, duration.to_s, limit.to_s, MAX_BATCH_BYTES.to_s]).as(Array)
      claims = Array(Claim).new(values.size)
      fallback = false
      values.each do |item|
        value = item.as(Array)
        if value[0].as(Int64) == -2
          fallback = true
          next
        end
        id, raw, attempt, token = value[1].as(String), value[2].as(String), value[3].as(Int64), value[4].as(String)
        begin
          entry = decode(id, raw)
        rescue CorruptRecord
          Scripts::QUARANTINE_CLAIM.call(@redis, keys + [quarantine_key], [id, token, owner, attempt.to_s, raw])
          next
        end
        claims << Claim.new(id, token, owner, attempt, entry.payload, entry.traceparent, entry.digest)
      end
      # Preserve the exact-Int64 CAS path; never round unsupported envelopes.
      claim(owner, lease).try { |value| claims << value } if fallback && claims.empty?
      claims
    end

    def settle_many(items : Array(Tuple(Claim, State, Time::Span))) : Array(Settlement)
      validate_batch_size(items.size)
      validate_batch_bytes(items.sum(0_i64) { |item| item[0].payload.bytesize.to_i64 })
      args = Array(String).new(items.size * 8)
      items.each do |claim, state, delay|
        unless state.completed? || state.dead? || state.scheduled?
          raise ArgumentError.new("settlement must be Completed, Dead or Scheduled")
        end
        raise ArgumentError.new("delay must be 0..365 days") unless Time::Span.zero <= delay <= 365.days
        args << claim.id << claim.token << claim.owner << claim.attempt.to_s << state.wire_name
        args << delay.total_milliseconds.to_i64.to_s << claim.payload << (claim.digest || Checksum.hex(claim.payload))
      end
      return items.map { |claim, state, delay| settle(claim, state, delay) } unless @optimized
      begin
        values = Scripts::SETTLE_MANY.call(@redis, keys, args).as(Array)
      rescue Redis::Error
        return Array.new(items.size, Settlement::Unknown)
      end
      items.map_with_index do |item, index|
        case values[index].as(Int64)
        when 0 then Settlement::Stale
        when 1 then Settlement::Applied
        when 2 then Settlement::AlreadyApplied
        else        settle(item[0], item[1], item[2])
        end
      end
    end

    # Batch reads still decode/checksum every canonical receipt, preserving the
    # benchmark's per-identity conservation check without a round trip per ID.
    def resolve_many(request_ids : Array(String)) : Array(Record?)
      validate_batch_size(request_ids.size)
      ids = request_ids.map { |request| identity(request) }
      values = @redis.hmget(records_key, ids)
      ids.map_with_index do |id, index|
        values[index].try { |raw| decode(id, raw.as(String)) }
      end
    end

    private def validate_batch_size(size : Int32) : Nil
      raise ArgumentError.new("batch size must be 1..#{MAX_BATCH}") unless 1 <= size <= MAX_BATCH
    end

    private def validate_batch_bytes(size : Int64) : Nil
      raise ArgumentError.new("batch payloads exceed #{MAX_BATCH_BYTES} bytes") if size > MAX_BATCH_BYTES
    end
  end
end
