module JoobQ::Delivery
  # Canonical operation document for durable outboxes. CAS has one mutation;
  # derived queue admissions are replayed by stable request ID after commit.
  class Journal(T)
    CAS = <<-LUA
      local old = redis.call('HGET', KEYS[1], ARGV[1])
      if ARGV[2] == '' then
        if old then return 0 end
        if redis.call('HLEN', KEYS[1]) >= tonumber(ARGV[4]) then return -1 end
      elseif old ~= ARGV[2] then return 0 end
      redis.call('HSET', KEYS[1], ARGV[1], ARGV[3])
      return 1
    LUA

    QUARANTINE = "if redis.call('HGET', KEYS[1], ARGV[1]) == ARGV[2] then return redis.call('HSET', KEYS[2], ARGV[1], ARGV[2]) end return 0"

    getter key : String
    getter quarantine_key : String

    def initialize(@redis : Redis::PooledClient, namespace : String, collection : String,
                   @capacity : Int32 = 100_000, @max_bytes : Int32 = 2_097_152)
      [namespace, collection].each do |name|
        raise ArgumentError.new("invalid journal namespace/collection") unless name.matches?(/\A[a-zA-Z0-9_.~-]{1,128}\z/)
      end
      raise ArgumentError.new("journal limits must be positive") unless @capacity > 0 && @max_bytes > 0
      @key = "joobq:v1:#{namespace}:journal:#{collection}"
      @quarantine_key = "#{@key}:quarantine"
    end

    def read(id : String) : {T, String}?
      raw = @redis.hget(key, identity(id)) || return
      {T.from_json(raw), raw}
    end

    def write(id : String, document : T, expected : String = "") : Bool
      raw = document.to_json
      raise ArgumentError.new("journal document exceeds byte limit") if raw.bytesize > @max_bytes
      code = @redis.eval(CAS, [key], [identity(id), expected, raw, @capacity.to_s]).as(Int64)
      raise ArgumentError.new("retained journal capacity reached") if code == -1
      code == 1
    end

    def each_page(cursor : String = "0", &block : T ->) : String
      next_cursor, values = @redis.hscan(key, cursor, count: 32)
      values.each do |id, raw|
        document = begin
          T.from_json(raw)
        rescue JSON::Error
          # Preserve the authoritative bytes for operator repair while letting
          # other valid intents in this page progress.
          @redis.eval(QUARANTINE, [key, quarantine_key], [id, raw])
          next
        end
        block.call(document)
      end
      next_cursor.as(String)
    end

    private def identity(id : String) : String
      raise ArgumentError.new("journal identity must be 1..1024 bytes") unless 1 <= id.bytesize <= 1024
      Digest::SHA256.hexdigest(id)
    end
  end
end
