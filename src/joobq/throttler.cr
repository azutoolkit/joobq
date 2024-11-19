module JoobQ
  # Throttler class to handle rate limiting
  class Throttler
    @limit : Int32
    @period : Float64

    def initialize(throttle_limit : NamedTuple(limit: Int32, period: Time::Span))
      @limit = throttle_limit[:limit]
      @period = throttle_limit[:period].total_milliseconds
      @min_interval = @period / @limit # milliseconds
      @last_job_time = Time.utc.to_unix_ms
    end

    def throttle
      now = Time.utc.to_unix_ms
      elapsed = now - @last_job_time
      sleep_time = @min_interval - elapsed
      if sleep_time > 0
        sleep (sleep_time / 1000.0).seconds
      end
      @last_job_time = Time.utc.to_unix_ms
    end
  end
end
