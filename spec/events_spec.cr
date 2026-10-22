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
