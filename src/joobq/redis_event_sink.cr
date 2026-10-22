module JoobQ
  # Persists events in a capped Redis Stream (replayable by id) and publishes
  # them on a pub/sub channel for live consumers. Delivery is batched: one
  # pipelined round trip appends to the stream, a second publishes the batch.
  class RedisEventSink
    include EventSink

    STREAM  = "joobq:events"
    LIVE    = "joobq:events:live"
    MAX_LEN = 50_000

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
