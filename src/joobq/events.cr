require "json"

module JoobQ
  # A lifecycle event (e.g. "job.started"). Wire form: {v, id?, ts, type, data}.
  struct Event
    include JSON::Serializable

    getter v : Int32 = 1
    getter id : String?
    getter ts : Int64
    getter type : String
    getter data : JSON::Any

    def initialize(@type : String, @data : JSON::Any, @ts : Int64 = Time.utc.to_unix_ms, @id : String? = nil)
    end

    def with_id(id : String) : Event
      Event.new(type, data, ts, id)
    end
  end

  # Observer interface: implement to receive lifecycle events.
  module EventSink
    abstract def publish(event : Event) : Nil

    # Sinks that can deliver in bulk (e.g. one pipelined round trip) override this.
    def publish_all(events : Array(Event)) : Nil
      events.each { |event| publish(event) }
    end
  end

  # Delivers events to sinks from a dedicated fiber, so emitting never blocks
  # or fails the caller. When the buffer is full the event is dropped and counted.
  class EventBus
    Log = ::Log.for("EVENTS")

    BATCH_SIZE         = 100
    ERROR_LOG_INTERVAL = 10.seconds

    getter dropped = Atomic(Int64).new(0)

    @sinks = [] of EventSink
    @active = Atomic(Bool).new(false)
    @lock = Sync::Mutex.new
    @started = Atomic(Bool).new(false)
    @last_error_log = Time.instant - ERROR_LOG_INTERVAL

    def initialize(capacity : Int32 = 4096)
      @events = Channel(Event).new(capacity)
      @done = Channel(Nil).new(1)
    end

    def active? : Bool
      @active.get
    end

    def subscribe(sink : EventSink) : Nil
      @lock.synchronize do
        @sinks = @sinks + [sink]
        @active.set(true)
      end
      start_dispatcher
    end

    def unsubscribe(sink : EventSink) : Nil
      @lock.synchronize do
        @sinks = @sinks - [sink]
        @active.set(!@sinks.empty?)
      end
    end

    # The block builds the payload and only runs when someone is listening.
    def emit(type : String, & : -> _) : Nil
      return unless active?

      event = Event.new(type, JSON.parse((yield).to_json))
      select
      when @events.send(event)
      else
        dropped.add(1)
      end
    rescue ex
      # Observability must never break the code path being observed.
      Log.debug &.emit("Event not emitted", type: type, error: ex.message)
    end

    # Stops accepting events, delivers what is buffered, and waits for the
    # dispatcher to finish (up to `wait`).
    def close(wait : Time::Span = 2.seconds) : Nil
      return unless @started.get

      @events.close
      select
      when @done.receive
      when timeout(wait)
        Log.warn &.emit("Events not fully delivered before shutdown")
      end
    end

    private def start_dispatcher
      _, first = @started.compare_and_set(false, true)
      return unless first

      spawn(name: "joobq-events") do
        while event = @events.receive?
          deliver(next_batch(event))
        end
        @done.send(nil)
      end
    end

    # The event that woke us plus whatever else is already waiting.
    private def next_batch(first : Event) : Array(Event)
      batch = [first]
      while batch.size < BATCH_SIZE
        select
        when event = @events.receive?
          event ? batch << event : break
        else
          break
        end
      end
      batch
    end

    private def deliver(batch : Array(Event)) : Nil
      @sinks.each do |sink|
        sink.publish_all(batch)
      rescue ex
        dropped.add(batch.size)
        log_sink_failure(sink, ex)
      end
    end

    # A dead sink fails every batch; log it once per interval, not per event.
    private def log_sink_failure(sink : EventSink, ex : Exception) : Nil
      return if Time.instant - @last_error_log < ERROR_LOG_INTERVAL

      @last_error_log = Time.instant
      Log.error &.emit("Sink failed", sink: sink.class.name, error: ex.message, dropped: dropped.get)
    end
  end

  # Process-wide bus used by the library itself.
  module Events
    BUS = EventBus.new

    def self.emit(type : String, & : -> _) : Nil
      BUS.emit(type) { yield }
    end

    def self.subscribe(sink : EventSink) : Nil
      BUS.subscribe(sink)
    end

    def self.unsubscribe(sink : EventSink) : Nil
      BUS.unsubscribe(sink)
    end
  end
end
