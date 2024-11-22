module JoobQ
  module Middleware
    class Throttle
      include Middleware

      private getter queue_throttle_limits : JoobQ::ThrottlerConfig
      private getter throttlers : Hash(String, Throttler) = {} of String => Throttler

      def initialize(@queue_throttle_limits = Configure::QUEUE_THROTTLE_LIMITS)
        build_throttlers
      end

      def matches?(job : JoobQ::Job, queue : BaseQueue) : Bool
        @queue_throttle_limits.has_key?(job.queue)
      end

      def call(job : JoobQ::Job, queue : BaseQueue, next_middleware : ->) : Nil
        throttlers[job.queue].throttle
        next_middleware.call
      end

      private def build_throttlers
        @queue_throttle_limits.map do |queue, throttle_limit|
          @throttlers[queue] = Throttler.new(throttle_limit)
        end
      end
    end
  end

  class Throttler
    @limit : Int32
    @period : Float64

    def initialize(throttle_limit : NamedTuple(limit: Int32, period: Time::Span))
      @limit = throttle_limit[:limit]
      @period = throttle_limit[:period].total_milliseconds
      @min_interval = @period / @limit # milliseconds
      @last_job_time = Time.local.to_unix_ms
    end

    def throttle
      now = Time.local.to_unix_ms
      elapsed = now - @last_job_time
      sleep_time = @min_interval - elapsed
      if sleep_time > 0
        sleep (sleep_time / 1000.0).seconds
      end
      @last_job_time = Time.local.to_unix_ms
    end
  end
end
