module JoobQ
  # Persists events in a capped Redis Stream (replayable by id) and publishes
  # them on a pub/sub channel for live consumers. Delivery is batched: one
  # pipelined round trip appends to the stream, a second publishes the batch.
  class RedisEventSink
    include EventSink

    STREAM  = "joobq:events"
    LIVE    = "joobq:events:live"
    MAX_LEN = 50_000

    TRIM_LOCK         = "joobq:events:trim_lock"
    TRIM_LOCK_SECONDS = 10
    DEFAULT_MAX_BYTES = 64_i64 * 1024 * 1024
    # The stream is never trimmed below this many entries, whatever they weigh.
    TRIM_FLOOR = 100_i64

    # The most memory the stream may use, in bytes (JOOBQ_EVENTS_MAX_BYTES; 0 turns the limit off, as does a
    # negative number). A value that is not a whole number is ignored with a warning.
    def self.max_bytes : Int64
      raw = ENV["JOOBQ_EVENTS_MAX_BYTES"]?.try(&.strip) || return DEFAULT_MAX_BYTES
      raw.to_i64? || begin
        ::Log.for("EVENT_SINK").warn { "JOOBQ_EVENTS_MAX_BYTES=#{raw.inspect} is not a whole number; using #{DEFAULT_MAX_BYTES}" }
        DEFAULT_MAX_BYTES
      end
    end

    # Drops the oldest entries when the stream uses more memory than `budget`; returns how many it dropped.
    # MAXLEN bounds the count only, and events with big payloads can make 50 000 entries very heavy. Only one
    # process checks per lock period (the lock is a throttle, not held during the trim), and the stream is trimmed to 90 % of the budget so it does not trim on every beat.
    def self.trim_to_bytes(redis : Redis::PooledClient = RedisStore.instance.redis, budget : Int64 = max_bytes) : Int64
      return 0_i64 if budget <= 0
      return 0_i64 unless redis.set(TRIM_LOCK, "1", ex: TRIM_LOCK_SECONDS, nx: true)

      usage = redis.command(["MEMORY", "USAGE", STREAM, "SAMPLES", "0"]).as?(Int64) || return 0_i64
      length = redis.command(["XLEN", STREAM]).as(Int64)
      return 0_i64 if usage <= budget || length <= TRIM_FLOOR

      keep = (length * (budget.to_f * 0.9 / usage)).to_i64.clamp(TRIM_FLOOR, length)
      redis.command(["XTRIM", STREAM, "MAXLEN", keep.to_s]).as(Int64)
    end

    def initialize(@redis : Redis::PooledClient = RedisStore.instance.redis)
    end

    def publish(event : Event) : Nil
      publish_all([event])
    end

    def publish_all(events : Array(Event)) : Nil
      ids = @redis.pipelined do |pipe|
        events.each do |event|
          pipe.command(["XADD", STREAM, "MAXLEN", "~", MAX_LEN.to_s, "*",
                        "ts", event.ts.to_s, "type", event.type, "data", event.data.to_json])
        end
      end
      @redis.pipelined do |pipe|
        events.zip(ids) { |event, id| pipe.publish(LIVE, event.with_id(id.to_s).to_json) }
      end
    end
  end
end
