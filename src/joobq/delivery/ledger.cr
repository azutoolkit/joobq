require "digest/sha256"

module JoobQ::Delivery
  # Versioned protocol prototype. Legacy queues do not read these keys. No
  # automatic retention: deleting receipts would invalidate idempotency.
  enum State
    Ready
    Leased
    Scheduled
    Completed
    Dead
  end

  enum AdmissionCode
    Accepted
    Rejected
    Unknown
  end

  enum Settlement
    Applied
    AlreadyApplied
    Stale
    Unknown
  end

  class CorruptRecord < Exception; end

  struct Record
    include JSON::Serializable
    include JSON::Serializable::Strict

    getter schema : Int32 = 1
    getter id : String
    getter payload : String
    getter digest : String
    property state : State = State::Ready
    property attempt : Int64 = 0_i64
    property token : String? = nil
    property owner : String? = nil
    property due_at : Int64 = 0_i64
    property lease_until : Int64 = 0_i64
    property traceparent : String? = nil

    def initialize(@id, @payload, @digest)
    end

    def validate! : self
      raise CorruptRecord.new("unsupported delivery schema") unless schema == 1
      begin
        TraceParent.parse(traceparent)
      rescue ArgumentError
        raise CorruptRecord.new("invalid delivery trace context")
      end
      raise CorruptRecord.new("invalid delivery record") if attempt < 0 || id.empty? || digest != Digest::SHA256.hexdigest(payload)
      if state.leased? && (token.nil? || owner.nil? || lease_until <= 0)
        raise CorruptRecord.new("leased delivery has no valid owner/token/deadline")
      end
      self
    end
  end

  record Admission, code : AdmissionCode, id : String, entry : Record? = nil, reason : String? = nil
  record Claim, id : String, token : String, owner : String, attempt : Int64, payload : String, traceparent : String? = nil, digest : String? = nil

  class Ledger
    # One authoritative write before derived indexes. If an index command fails,
    # canonical intent survives and repair reconstructs it. Never assume rollback.
    WRITE = <<-LUA
      local old = redis.call('HGET', KEYS[1], ARGV[1])
      if ARGV[2] == '' then
        if old then return 0 end
        if redis.call('HLEN', KEYS[1]) >= tonumber(ARGV[8]) then return -1 end
      elseif old ~= ARGV[2] then return 0 end
      local clock = redis.call('TIME')
      local now = tonumber(clock[1]) * 1000 + math.floor(tonumber(clock[2]) / 1000)
      -- Validate time inside the same atomic operation as the ownership CAS.
      if ARGV[6] ~= '' and now >= tonumber(ARGV[6]) then return 0 end
      if ARGV[7] ~= '' and now < tonumber(ARGV[7]) then return 0 end
      if ARGV[5] ~= '' and now >= tonumber(ARGV[5]) then return 0 end
      if ARGV[5] ~= '' and redis.call('EXISTS', KEYS[4]) == 1 then return 0 end
      redis.call('HSET', KEYS[1], ARGV[1], ARGV[3])
      redis.call('ZREM', KEYS[2], ARGV[1])
      redis.call('ZREM', KEYS[3], ARGV[1])
      if ARGV[4] ~= '' then redis.call('ZADD', KEYS[2], ARGV[4], ARGV[1]) end
      if ARGV[5] ~= '' then redis.call('ZADD', KEYS[3], ARGV[5], ARGV[1]) end
      return 1
    LUA

    # Repair checks the exact observed canonical record, so a stale repair pass
    # cannot overwrite indexes for a newer claim or terminal outcome.
    REPAIR = <<-LUA
      if redis.call('HGET', KEYS[1], ARGV[1]) ~= ARGV[2] then return 0 end
      redis.call('ZREM', KEYS[2], ARGV[1])
      redis.call('ZREM', KEYS[3], ARGV[1])
      if ARGV[3] ~= '' then redis.call('ZADD', KEYS[2], ARGV[3], ARGV[1]) end
      if ARGV[4] ~= '' then redis.call('ZADD', KEYS[3], ARGV[4], ARGV[1]) end
      return 1
    LUA

    @keys : Array(String)
    @record_limit : String

    getter records_key : String
    getter ready_key : String
    getter leases_key : String
    getter gate_key : String
    getter quarantine_key : String

    def initialize(@redis : Redis::PooledClient, namespace : String, queue : String, @max_payload_bytes : Int32 = 1_048_576, @max_records : Int32 = 100_000, @optimized : Bool = true)
      [namespace, queue].each do |name|
        raise ArgumentError.new("namespace and queue must be 1..128 safe characters") unless name.matches?(/\A[a-zA-Z0-9_.~-]{1,128}\z/)
      end
      raise ArgumentError.new("record limit must be positive") unless @max_records > 0
      raise ArgumentError.new("payload limit must be positive") unless @max_payload_bytes > 0
      prefix = "joobq:v1:#{namespace}:#{queue}"
      @gate_key = "joobq:v1:#{namespace}:maintenance"
      @quarantine_key = "#{prefix}:quarantine"
      @records_key, @ready_key, @leases_key = "#{prefix}:records", "#{prefix}:ready", "#{prefix}:leases"
      @keys = [records_key, ready_key, leases_key, gate_key]
      @record_limit = @max_records.to_s
    end

    def admit(request_id : String, payload : String, delay : Time::Span = Time::Span.zero, traceparent : String? = nil) : Admission
      TraceParent.parse(traceparent)
      raise ArgumentError.new("admission delay must be 0..365 days") unless Time::Span.zero <= delay <= 365.days
      id = identity(request_id)
      if payload.empty? || payload.bytesize > @max_payload_bytes
        return Admission.new(AdmissionCode::Rejected, id, reason: "payload size is outside the configured limit")
      end
      if @optimized
        entry = Record.new(id, payload, Digest::SHA256.hexdigest(payload))
        entry.traceparent = traceparent
        entry.state = State::Scheduled if delay > Time::Span.zero
        result = Scripts::ADMIT.call(@redis, keys, [id, entry.to_json, delay.total_milliseconds.to_i64.to_s, @record_limit]).as(Array)
        case result[0].as(Int64)
        when -1
          return Admission.new(AdmissionCode::Rejected, id, reason: "retained record capacity reached")
        when 1
          return admission_for(decode(id, result[1].as(String)), id, payload)
        end
      end
      if existing = load(id)
        return admission_for(existing[0], id, payload)
      end
      entry = Record.new(id, payload, Digest::SHA256.hexdigest(payload))
      entry.traceparent = traceparent
      entry.state = State::Scheduled if delay > Time::Span.zero
      entry.due_at = now_ms + delay.total_milliseconds.to_i64
      written = write_code(entry, "")
      return Admission.new(AdmissionCode::Rejected, id, reason: "retained record capacity reached") if written == -1
      # Also handles a competing producer that won the HSET admission.
      if current = load(id)
        admission_for(current[0], id, payload)
      else
        Admission.new(AdmissionCode::Unknown, id, reason: "receipt unavailable")
      end
    rescue Redis::Error
      Admission.new(AdmissionCode::Unknown, identity(request_id), reason: "Redis did not confirm admission; resolve the same request ID")
    end

    def resolve(request_id : String) : Record?
      load(identity(request_id)).try(&.[0])
    end

    def claim(owner : String, lease : Time::Span = 30.seconds) : Claim?
      raise ArgumentError.new("owner must not be empty") if owner.empty?
      duration = positive_ms(lease)
      if @optimized
        token = UUID.random.to_s
        result = Scripts::CLAIM.call(@redis, keys, [owner, token, duration.to_s]).as(Array)
        case result[0].as(Int64)
        when 0
          return nil
        when 1
          id = result[1].as(String)
          original = result[2].as(String)
          attempt = result[3].as(Int64)
          begin
            entry = decode(id, original)
          rescue CorruptRecord
            Scripts::QUARANTINE_CLAIM.call(@redis, keys + [quarantine_key], [id, token, owner, attempt.to_s, original])
            return nil
          end
          return Claim.new(id, token, owner, attempt, entry.payload, entry.traceparent, entry.digest)
        end
      end
      now = now_ms
      @redis.zrangebyscore(ready_key, "-inf", now.to_s, limit: [0, 100]).each do |value|
        id = value.as(String)
        begin
          entry, raw = load(id) || next
        rescue CorruptRecord
          quarantine(id)
          next
        end
        next unless (entry.state.ready? || entry.state.scheduled?) && entry.due_at <= now
        entry.state = State::Leased
        entry.attempt += 1
        token = UUID.random.to_s
        entry.token = token
        entry.owner = owner
        entry.lease_until = now + duration
        if write(entry, raw)
          return Claim.new(id, token, owner, entry.attempt, entry.payload, entry.traceparent, entry.digest)
        end
      end
      nil
    end

    def renew(claim : Claim, lease : Time::Span = 30.seconds) : Settlement
      duration = positive_ms(lease)
      if @optimized && (result = transition(claim, State::Leased, duration))
        return result
      end
      entry, raw = load(claim.id) || return Settlement::Stale
      return Settlement::Stale unless owns?(entry, claim) && entry.lease_until > now_ms
      previous_deadline = entry.lease_until
      entry.lease_until = now_ms + duration
      write(entry, raw, before: previous_deadline) ? Settlement::Applied : Settlement::Stale
    rescue Redis::Error
      Settlement::Unknown
    end

    def settle(claim : Claim, state : State = State::Completed, delay : Time::Span = Time::Span.zero) : Settlement
      unless state.completed? || state.dead? || state.scheduled?
        raise ArgumentError.new("settlement must be Completed, Dead or Scheduled")
      end
      raise ArgumentError.new("delay must be 0..365 days") unless Time::Span.zero <= delay <= 365.days
      if @optimized && (result = transition(claim, state, delay.total_milliseconds.to_i64))
        return result
      end
      entry, raw = load(claim.id) || return Settlement::Stale
      same_claim = entry.token == claim.token && entry.owner == claim.owner && entry.attempt == claim.attempt
      return Settlement::AlreadyApplied if same_claim && entry.state == state
      return Settlement::Stale unless owns?(entry, claim) && entry.lease_until > now_ms
      previous_deadline = entry.lease_until
      entry.state = state
      entry.lease_until = 0_i64
      entry.due_at = now_ms + delay.total_milliseconds.to_i64
      write(entry, raw, before: previous_deadline) ? Settlement::Applied : Settlement::Stale
    rescue Redis::Error
      Settlement::Unknown
    end

    # One HSCAN page (COUNT is a Redis work hint, not a strict result cap).
    # Continue with the returned cursor until "0";
    # schedule repeated full cycles to repair missed indexes and expired leases.
    def repair(cursor : String = "0", count : Int32 = 100) : String
      raise ArgumentError.new("repair count must be between 1 and 1000") unless 1 <= count <= 1000
      result = @redis.hscan(records_key, cursor, count: count)
      next_cursor = result[0].as(String)
      result[1].each do |id, raw|
        begin
          entry = decode(id, raw)
        rescue CorruptRecord
          quarantine(id)
          next
        end
        if entry.state.leased? && entry.lease_until <= now_ms
          expired_deadline = entry.lease_until
          entry.state = State::Ready
          entry.token = nil
          entry.owner = nil
          entry.lease_until = 0_i64
          entry.due_at = 0_i64
          write(entry, raw, after: expired_deadline)
        else
          ready, leased = scores(entry)
          @redis.eval(REPAIR, keys, [id, raw, ready, leased])
        end
      end
      next_cursor
    end

    # Offline migration only. The operator-owned gate prevents claims while the
    # imported set is verified. Existing identities must agree exactly.
    def import(request_id : String, payload : String, state : State, due_at : Int64, owner : String) : Admission
      raise ArgumentError.new("migration gate is not owned") unless @redis.get(gate_key) == owner
      raise ArgumentError.new("cannot import a leased state") if state.leased?
      id = identity(request_id)
      if existing = load(id)
        entry = existing[0]
        unless entry.payload == payload && entry.state == state && entry.due_at == due_at
          raise ArgumentError.new("migration identity conflict; originals retained")
        end
        return Admission.new(AdmissionCode::Accepted, id, entry)
      end
      raise ArgumentError.new("invalid imported payload size") unless 1 <= payload.bytesize <= @max_payload_bytes
      entry = Record.new(id, payload, Digest::SHA256.hexdigest(payload))
      entry.state = state
      entry.due_at = due_at
      code = write_code(entry, "")
      return Admission.new(AdmissionCode::Rejected, id, reason: "retained record capacity reached") if code == -1
      current = load(id) || return Admission.new(AdmissionCode::Unknown, id)
      unless current[0].payload == payload && current[0].state == state && current[0].due_at == due_at
        raise ArgumentError.new("migration identity conflict")
      end
      Admission.new(AdmissionCode::Accepted, id, current[0])
    rescue Redis::Error
      Admission.new(AdmissionCode::Unknown, identity(request_id))
    end

    QUARANTINE = <<-LUA
      local raw = redis.call('HGET', KEYS[1], ARGV[1])
      if raw ~= ARGV[2] then return 0 end
      redis.call('HSET', KEYS[4], ARGV[1], raw)
      redis.call('ZREM', KEYS[2], ARGV[1])
      redis.call('ZREM', KEYS[3], ARGV[1])
      return 1
    LUA

    private def quarantine(id : String) : Nil
      raw = @redis.hget(records_key, id) || return
      # Retain the authoritative raw bytes and a diagnostic index. Never erase
      # unknown schemas merely to keep the healthy queue moving.
      @redis.eval(QUARANTINE, [records_key, ready_key, leases_key, quarantine_key], [id, raw])
    end

    private def keys : Array(String)
      @keys
    end

    private def transition(claim : Claim, state : State, duration : Int64) : Settlement?
      result = Scripts::TRANSITION.call(@redis, keys, [claim.id, claim.token, claim.owner, claim.attempt.to_s,
                                                       state.to_s.downcase, duration.to_s, claim.payload, claim.digest || Digest::SHA256.hexdigest(claim.payload)]).as(Array)
      case result[0].as(Int64)
      when 0 then Settlement::Stale
      when 1 then Settlement::Applied
      when 2 then Settlement::AlreadyApplied
      else        nil # Preserve exact Int64/legacy envelope handling in the CAS path.
      end
    end

    private def scores(entry : Record) : {String, String}
      {entry.state.ready? || entry.state.scheduled? ? entry.due_at.to_s : "",
       entry.state.leased? ? entry.lease_until.to_s : ""}
    end

    private def write(entry : Record, expected : String, before : Int64? = nil, after : Int64? = nil) : Bool
      write_code(entry, expected, before, after) == 1
    end

    private def write_code(entry : Record, expected : String, before : Int64? = nil, after : Int64? = nil) : Int64
      ready, leased = scores(entry)
      @redis.eval(WRITE, keys, [entry.id, expected, entry.to_json, ready, leased, before.to_s, after.to_s, @max_records.to_s]).as(Int64)
    end

    private def load(id : String) : {Record, String}?
      raw = @redis.hget(records_key, id) || return
      {decode(id, raw), raw}
    end

    private def decode(id : String, raw : String) : Record
      entry = Record.from_json(raw).validate!
      raise CorruptRecord.new("delivery identity does not match record key") unless entry.id == id
      entry
    rescue ex : JSON::Error
      raise CorruptRecord.new("delivery envelope cannot be decoded (#{ex.class})")
    end

    private def identity(request : String) : String
      raise ArgumentError.new("request ID must be 1..1024 bytes") unless 1 <= request.bytesize <= 1024
      Digest::SHA256.hexdigest(request)
    end

    private def admission_for(entry : Record, id : String, payload : String) : Admission
      if entry.payload == payload
        Admission.new(AdmissionCode::Accepted, id, entry)
      else
        Admission.new(AdmissionCode::Rejected, id, reason: "request ID already has a different payload")
      end
    end

    private def owns?(entry : Record, claim : Claim) : Bool
      entry.state.leased? && entry.token == claim.token && entry.owner == claim.owner && entry.attempt == claim.attempt
    end

    private def positive_ms(span : Time::Span) : Int64
      ms = span.total_milliseconds.to_i64
      raise ArgumentError.new("lease must be between 1 ms and 24 hours") unless 1 <= ms <= 86_400_000
      ms
    end

    private def now_ms : Int64
      time = @redis.command(["TIME"]).as(Array)
      time[0].as(String).to_i64 * 1000 + time[1].as(String).to_i64 // 1000
    end
  end
end
