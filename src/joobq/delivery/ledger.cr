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

    def initialize(@id, @payload, @digest)
    end

    def validate! : self
      raise CorruptRecord.new("unsupported delivery schema") unless schema == 1
      raise CorruptRecord.new("invalid delivery record") if attempt < 0 || id.empty? || digest != Digest::SHA256.hexdigest(payload)
      if state.leased? && (token.nil? || owner.nil? || lease_until <= 0)
        raise CorruptRecord.new("leased delivery has no valid owner/token/deadline")
      end
      self
    end
  end

  record Admission, code : AdmissionCode, id : String, entry : Record? = nil, reason : String? = nil
  record Claim, id : String, token : String, owner : String, attempt : Int64, payload : String

  class Ledger
    # One authoritative write before derived indexes. If an index command fails,
    # canonical intent survives and repair reconstructs it. Never assume rollback.
    WRITE = <<-LUA
      local old = redis.call('HGET', KEYS[1], ARGV[1])
      if ARGV[2] == '' then
        if old then return 0 end
      elseif old ~= ARGV[2] then return 0 end
      local clock = redis.call('TIME')
      local now = tonumber(clock[1]) * 1000 + math.floor(tonumber(clock[2]) / 1000)
      -- Validate time inside the same atomic operation as the ownership CAS.
      if ARGV[6] ~= '' and now >= tonumber(ARGV[6]) then return 0 end
      if ARGV[7] ~= '' and now < tonumber(ARGV[7]) then return 0 end
      if ARGV[5] ~= '' and now >= tonumber(ARGV[5]) then return 0 end
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

    getter records_key : String
    getter ready_key : String
    getter leases_key : String

    def initialize(@redis : Redis::PooledClient, namespace : String, queue : String, @max_payload_bytes : Int32 = 1_048_576)
      [namespace, queue].each do |name|
        raise ArgumentError.new("namespace and queue must be 1..128 safe characters") unless name.matches?(/\A[a-zA-Z0-9_.~-]{1,128}\z/)
      end
      raise ArgumentError.new("payload limit must be positive") unless @max_payload_bytes > 0
      prefix = "joobq:v1:#{namespace}:#{queue}"
      @records_key, @ready_key, @leases_key = "#{prefix}:records", "#{prefix}:ready", "#{prefix}:leases"
    end

    def admit(request_id : String, payload : String) : Admission
      id = identity(request_id)
      if payload.empty? || payload.bytesize > @max_payload_bytes
        return Admission.new(AdmissionCode::Rejected, id, reason: "payload size is outside the configured limit")
      end
      if existing = load(id)
        return admission_for(existing[0], id, payload)
      end
      entry = Record.new(id, payload, Digest::SHA256.hexdigest(payload))
      write(entry, "")
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
      now = now_ms
      @redis.zrangebyscore(ready_key, "-inf", now.to_s, limit: [0, 100]).each do |value|
        id = value.as(String)
        entry, raw = load(id) || next
        next unless (entry.state.ready? || entry.state.scheduled?) && entry.due_at <= now
        entry.state = State::Leased
        entry.attempt += 1
        token = UUID.random.to_s
        entry.token = token
        entry.owner = owner
        entry.lease_until = now + duration
        if write(entry, raw)
          return Claim.new(id, token, owner, entry.attempt, entry.payload)
        end
      end
      nil
    end

    def renew(claim : Claim, lease : Time::Span = 30.seconds) : Settlement
      duration = positive_ms(lease)
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
      raise ArgumentError.new("delay must not be negative") if delay < Time::Span.zero
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
        entry = decode(id, raw)
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

    private def keys : Array(String)
      [records_key, ready_key, leases_key]
    end

    private def scores(entry : Record) : {String, String}
      {entry.state.ready? || entry.state.scheduled? ? entry.due_at.to_s : "",
       entry.state.leased? ? entry.lease_until.to_s : ""}
    end

    private def write(entry : Record, expected : String, before : Int64? = nil, after : Int64? = nil) : Bool
      ready, leased = scores(entry)
      @redis.eval(WRITE, keys, [entry.id, expected, entry.to_json, ready, leased, before.to_s, after.to_s]) == 1
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
