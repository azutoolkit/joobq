require "base64"

module JoobQ::Delivery
  class Migration
    record Report, logical_records : Int32, source_entries : Int32, digest : String do
      include JSON::Serializable
    end

    RELEASE = "if redis.call('GET', KEYS[1]) == ARGV[1] then return redis.call('DEL', KEYS[1]) end return 0"

    def initialize(@ledger : Ledger, @redis : Redis::PooledClient, @queue : String, @owner : String)
      raise ArgumentError.new("migration owner must not be empty") if @owner.empty?
    end

    # Caller must stop old producers/workers first. Originals are retained. The
    # second inventory detects concurrent source changes and leaves ingress gated.
    def run(quiescent : Bool = false) : Report
      raise ArgumentError.new("stop legacy producers/workers and explicitly confirm quiescence") unless quiescent
      current = @redis.get(@ledger.gate_key)
      unless current == @owner || @redis.set(@ledger.gate_key, @owner, nx: true) == "OK"
        raise ArgumentError.new("namespace is owned by another maintenance operation")
      end
      before = inventory
      before.each_value do |entry|
        result = @ledger.import(entry[0], entry[1], entry[2], entry[3], @owner)
        raise AdmissionFailed.new(result) unless result.code.accepted?
      end
      after = inventory
      raise "legacy source changed during migration; target remains gated" unless before == after
      digest = Digest::SHA256.hexdigest(before.to_a.sort_by(&.[0]).to_json)
      Report.new(before.size, @source_entries, digest)
    end

    # Explicit cutover only after operators verify the report and backup. Normal
    # restart of the migrator cannot accidentally unpause a partially imported set.
    def activate(report : Report) : Nil
      current = inventory
      digest = Digest::SHA256.hexdigest(current.to_a.sort_by(&.[0]).to_json)
      raise "source changed since verification" unless digest == report.digest
      current.each_value do |entry|
        record = @ledger.resolve(entry[0]) || raise "missing imported receipt"
        unless record.payload == entry[1] && record.state == entry[2] && record.due_at == entry[3]
          raise "target differs from verified migration"
        end
      end
      raise "migration gate ownership lost" unless @redis.eval(RELEASE, [@ledger.gate_key], [@owner]) == 1
    end

    @source_entries = 0

    private def inventory
      entries = {} of String => Tuple(String, String, State, Int64)
      @source_entries = 0
      [@queue, "joobq:processing:#{@queue}"].each do |key|
        offset = 0
        loop do
          page = @redis.lrange(key, offset, offset + 99)
          break if page.empty?
          page.each { |raw| add(entries, raw.as(String), State::Ready, 0_i64) }
          offset += page.size
        end
      end
      [{RedisStore::DELAYED_SET, State::Scheduled}, {DeadLetterQueue::KEY, State::Dead}].each do |key, state|
        cursor = "0"
        loop do
          cursor_value, members = @redis.zscan(key, cursor, count: 100)
          cursor = cursor_value.as(String)
          # crystal-redis returns the raw alternating member/score array.
          members.as(Array).each_slice(2) do |pair|
            raw = pair[0].as(String)
            parsed = JSON.parse(raw)
            next unless parsed["queue"]?.try(&.as_s?) == @queue
            due = state.scheduled? ? pair[1].as(String).to_f64.to_i64 : 0_i64
            add(entries, raw, state, due)
          end
          break if cursor == "0"
        end
      end
      entries
    end

    private def add(entries, raw : String, state : State, due : Int64) : Nil
      @source_entries += 1
      begin
        parsed = JSON.parse(raw)
        jid = parsed["jid"]?.try(&.as_s?) || raise ArgumentError.new("legacy job has no jid")
        raise ArgumentError.new("legacy queue mismatch") unless parsed["queue"]?.try(&.as_s?) == @queue
        id = "legacy:#{jid}"
      rescue JSON::Error
        id = "legacy-invalid:#{Digest::SHA256.hexdigest(raw)}"
        state = State::Dead
        due = 0_i64
      end
      value = {id, raw, state, due}
      if previous = entries[id]?
        raise "conflicting legacy copies for #{id}; resolve before cutover" unless previous == value
      end
      entries[id] = value
    end
  end

  # Portable namespace backup. DUMP preserves opaque payload bytes and key types.
  # Restore rejects foreign keys, corruption and divergent target data before any
  # mutation; an interrupted restore can be resumed against matching partial data.
  class Backup
    record Entry, key : String, bytes : String, digest : String do
      include JSON::Serializable
    end
    record Image, schema : Int32, namespace : String, entries : Array(Entry) do
      include JSON::Serializable
    end

    def initialize(@redis : Redis::PooledClient, @namespace : String)
      raise ArgumentError.new("invalid namespace") unless @namespace.matches?(/\A[a-zA-Z0-9_.~-]{1,128}\z/)
      @prefix = "joobq:v1:#{@namespace}:"
    end

    def export(io : IO, quiescent : Bool = false) : Nil
      raise ArgumentError.new("backup requires stopped writers") unless quiescent
      entries = keys.sort.map do |key|
        raise ArgumentError.new("namespace backup supports persistent keys only") unless @redis.pttl(key) == -1
        bytes = @redis.command(["DUMP", key]).as(String)
        Entry.new(key, Base64.strict_encode(bytes), Digest::SHA256.hexdigest(bytes))
      end
      raise "namespace changed during backup" unless entries.map(&.key) == keys.sort
      entries.each do |entry|
        raise ArgumentError.new("namespace backup supports persistent keys only") unless @redis.pttl(entry.key) == -1
        raise "namespace changed during backup" unless @redis.command(["DUMP", entry.key]).as?(String).try { |bytes| Digest::SHA256.hexdigest(bytes) } == entry.digest
      end
      Image.new(1, @namespace, entries).to_json(io)
    end

    def restore(io : IO) : Int32
      image = Image.from_json(io)
      raise ArgumentError.new("backup schema/namespace mismatch") unless image.schema == 1 && image.namespace == @namespace
      expected = {} of String => String
      image.entries.each do |entry|
        raise ArgumentError.new("foreign or duplicate backup key") unless entry.key.starts_with?(@prefix) && !expected.has_key?(entry.key)
        raw = String.new(Base64.decode(entry.bytes))
        raise ArgumentError.new("backup digest mismatch") unless Digest::SHA256.hexdigest(raw) == entry.digest
        expected[entry.key] = raw
      end
      keys.each do |key|
        raise ArgumentError.new("target contains unrelated keys") unless expected.has_key?(key)
        raise ArgumentError.new("target differs from backup") unless @redis.command(["DUMP", key]).as(String) == expected[key]
      end
      expected.each do |key, raw|
        next if @redis.exists(key) > 0
        @redis.command(["RESTORE", key, "0", raw])
      end
      expected.size
    end

    private def keys : Array(String)
      cursor = "0"
      found = [] of String
      loop do
        cursor_value, values = @redis.scan(cursor, match: "#{@prefix}*", count: 100)
        cursor = cursor_value.as(String)
        values.as(Array).each { |value| found << value.as(String) }
        break if cursor == "0"
      end
      found.uniq
    end
  end
end
