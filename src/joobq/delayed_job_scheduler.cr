module JoobQ
  class DelayedJobScheduler
    def initialize(@store : Store = RedisStore.instance)
    end

    def delay(job : Job, delay_time : Time::Span)
      delay_in_ms = delay_time.from_now.to_unix_ms
      @store.schedule(job, delay_in_ms)
    end
  end
end
