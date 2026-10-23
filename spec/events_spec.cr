require "./spec_helper"

module JoobQ
  class FailingSink
    include EventSink

    def publish(event : Event) : Nil
      raise "sink down"
    end
  end

  class BlockingSink
    include EventSink

    getter gate = Channel(Nil).new

    def publish(event : Event) : Nil
      gate.receive
    end
  end

  describe EventBus do
    it "delivers emitted events to subscribed sinks" do
      bus = EventBus.new
      sink = CollectingSink.new
      bus.subscribe(sink)

      bus.emit("job.started") { {jid: "abc", queue: "q"} }

      event = JoobQ.receive_event(sink)
      event.type.should eq("job.started")
      event.data["jid"].as_s.should eq("abc")
      event.v.should eq(1)
    end

    it "keeps delivering to other sinks when one fails" do
      bus = EventBus.new
      sink = CollectingSink.new
      bus.subscribe(FailingSink.new)
      bus.subscribe(sink)

      bus.emit("queue.paused") { {queue: "q"} }

      JoobQ.receive_event(sink).type.should eq("queue.paused")
    end

    it "does not even build the payload without subscribers" do
      bus = EventBus.new
      built = false
      bus.emit("job.started") { built = true; {jid: "x"} }

      built.should be_false
      bus.dropped.get.should eq(0)
    end

    it "drops and counts events instead of blocking when the buffer is full" do
      bus = EventBus.new(capacity: 2)
      sink = BlockingSink.new
      bus.subscribe(sink)

      20.times { |i| bus.emit("job.started") { {n: i} } }

      bus.dropped.get.should be > 0
      sink.gate.close
    end
  end

  describe RedisEventSink do
    it "appends to the stream and publishes with the stream id" do
      store = JoobQ.store.as(RedisStore)
      store.redis.del(RedisEventSink::STREAM)

      sink = RedisEventSink.new(store.redis)
      sink.publish(Event.new("job.dead", JSON.parse(%({"jid":"j1"}))))

      entries = store.redis.command(["XRANGE", RedisEventSink::STREAM, "-", "+"]).as(Array)
      entries.size.should eq(1)
    end

    describe ".trim_to_bytes" do
      fill = ->(store : RedisStore, entries : Int32) do
        store.redis.del(RedisEventSink::STREAM, RedisEventSink::TRIM_LOCK)
        payload = JSON.parse(%({"blob":"#{"x" * 2000}"}))
        RedisEventSink.new(store.redis).publish_all((1..entries).map { Event.new("job.enqueued", payload) })
      end
      length = ->(store : RedisStore) { store.redis.command(["XLEN", RedisEventSink::STREAM]).as(Int64) }

      it "drops the oldest entries when the stream outgrows its budget" do
        store = JoobQ.store.as(RedisStore)
        fill.call(store, 500)

        dropped = RedisEventSink.trim_to_bytes(store.redis, 300_000_i64)

        dropped.should be > 0
        length.call(store).should eq(500 - dropped)
        usage = store.redis.command(["MEMORY", "USAGE", RedisEventSink::STREAM, "SAMPLES", "0"]).as(Int64)
        usage.should be <= 300_000
        newest = store.redis.command(["XREVRANGE", RedisEventSink::STREAM, "+", "-", "COUNT", "1"]).as(Array)
        newest.size.should eq(1) # the newest entries are the ones kept
      end

      it "leaves a stream alone that fits, and does nothing when the budget is 0" do
        store = JoobQ.store.as(RedisStore)
        fill.call(store, 300)
        RedisEventSink.trim_to_bytes(store.redis, 1_000_000_000_i64).should eq(0)
        store.redis.del(RedisEventSink::TRIM_LOCK)
        RedisEventSink.trim_to_bytes(store.redis, 0_i64).should eq(0)
        length.call(store).should eq(300)
      end

      it "does nothing when the stream does not exist" do
        store = JoobQ.store.as(RedisStore)
        store.redis.del(RedisEventSink::STREAM, RedisEventSink::TRIM_LOCK)
        RedisEventSink.trim_to_bytes(store.redis, 1_i64).should eq(0)
      end

      it "reads the budget from JOOBQ_EVENTS_MAX_BYTES" do
        saved = ENV["JOOBQ_EVENTS_MAX_BYTES"]?
        begin
          ENV.delete("JOOBQ_EVENTS_MAX_BYTES")
          RedisEventSink.max_bytes.should eq(RedisEventSink::DEFAULT_MAX_BYTES)
          ENV["JOOBQ_EVENTS_MAX_BYTES"] = " 1234 "
          RedisEventSink.max_bytes.should eq(1234)
          ENV["JOOBQ_EVENTS_MAX_BYTES"] = "0"
          RedisEventSink.max_bytes.should eq(0)
          ENV["JOOBQ_EVENTS_MAX_BYTES"] = "64MB"
          RedisEventSink.max_bytes.should eq(RedisEventSink::DEFAULT_MAX_BYTES)
        ensure
          saved ? (ENV["JOOBQ_EVENTS_MAX_BYTES"] = saved) : ENV.delete("JOOBQ_EVENTS_MAX_BYTES")
        end
      end

      it "keeps a floor of entries even under a tiny budget" do
        store = JoobQ.store.as(RedisStore)
        fill.call(store, 400)
        RedisEventSink.trim_to_bytes(store.redis, 1_i64)
        length.call(store).should eq(RedisEventSink::TRIM_FLOOR)
      end

      it "lets one process trim at a time" do
        store = JoobQ.store.as(RedisStore)
        fill.call(store, 500)
        RedisEventSink.trim_to_bytes(store.redis, 300_000_i64).should be > 0
        fill.call(store, 500)
        store.redis.set(RedisEventSink::TRIM_LOCK, "1", ex: 10)
        RedisEventSink.trim_to_bytes(store.redis, 300_000_i64).should eq(0)
        length.call(store).should eq(500)
      end
    end

    it "delivers a batch in one go, preserving order" do
      store = JoobQ.store.as(RedisStore)
      store.redis.del(RedisEventSink::STREAM)

      batch = (1..3).map { |i| Event.new("job.enqueued", JSON.parse(%({"n":#{i}}))) }
      RedisEventSink.new(store.redis).publish_all(batch)

      entries = store.redis.command(["XRANGE", RedisEventSink::STREAM, "-", "+"]).as(Array)
      entries.size.should eq(3)
    end

    it "delivers buffered events before close returns" do
      bus = EventBus.new
      sink = CollectingSink.new
      bus.subscribe(sink)
      3.times { |i| bus.emit("job.started") { {n: i} } }

      bus.close

      3.times.map { JoobQ.receive_event(sink).data["n"].as_i }.to_a.should eq([0, 1, 2])
    end
  end
end
