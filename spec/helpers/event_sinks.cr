module JoobQ
  class CollectingSink
    include EventSink

    getter received = Channel(Event).new(64)

    def publish(event : Event) : Nil
      received.send(event)
    end
  end

  def self.receive_event(sink : CollectingSink) : Event
    select
    when event = sink.received.receive
      event
    when timeout(2.seconds)
      raise "no event received"
    end
  end
end
