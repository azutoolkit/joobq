module JoobQ
  # A boolean read from a remote source, refreshed at most once per `ttl`.
  # A failing load keeps the last known value, so a source outage never
  # propagates into the callers' hot paths, and a local `set` always wins over
  # a load that was already in flight.
  class CachedFlag
    Log = ::Log.for("CACHED_FLAG")

    private ORIGIN = Time.instant

    @value = Atomic(Bool).new(false)
    @loaded_at = Atomic(Int64).new(Int64::MIN // 2) # long ago, without overflowing on subtraction
    @generation = Atomic(Int32).new(0)

    def initialize(@ttl : Time::Span, &@load : -> Bool)
    end

    def get : Bool
      now = elapsed_ns
      seen = @loaded_at.get
      return @value.get if now - seen < @ttl.total_nanoseconds

      # One caller refreshes; the rest keep the cached value meanwhile.
      _, won = @loaded_at.compare_and_set(seen, now)
      return @value.get unless won

      generation = @generation.get
      loaded = @load.call
      @value.set(loaded) if @generation.get == generation
      @value.get
    rescue ex
      Log.warn &.emit("Flag refresh failed, keeping last value", error: ex.message)
      @value.get
    end

    # Applies a change made by this process immediately.
    def set(value : Bool) : Nil
      @generation.add(1)
      @value.set(value)
      @loaded_at.set(elapsed_ns)
    end

    private def elapsed_ns : Int64
      (Time.instant - ORIGIN).total_nanoseconds.to_i64
    end
  end
end
