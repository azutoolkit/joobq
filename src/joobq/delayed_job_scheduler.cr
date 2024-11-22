module JoobQ
  class DelayedJobScheduler
    def initialize(@store : Store = RedisStore.instance)
    end

    def delay(job : Job, delay_time : Time::Span)
      raise ArgumentError.new("Delay must be positive") if delay_time <= Time::Span.new(0)
      delay_in_ms = delay_time.from_now.to_unix_ms
      @store.schedule(job, delay_in_ms)
    end
  end
end
