module JoobQ
  module Middleware
    class Throttle
      include Middleware

      private getter last_job_times : Hash(String, Int64) = {} of String => Int64
      private getter mutex : Mutex = Mutex.new

      def matches?(job : JoobQ::Job, queue : BaseQueue) : Bool
        !queue.throttle_limit.nil?
      end

      def call(job : JoobQ::Job, queue : BaseQueue, worker_id : String, next_middleware : ->) : Nil
        throttle(queue)
        next_middleware.call
      end

      private def throttle(queue : BaseQueue)
        if throttle = queue.throttle_limit
          limit = throttle[:limit]
          period = throttle[:period].total_milliseconds

          min_interval = period / limit

          # Use mutex to prevent race condition when multiple workers access last_job_times
          @mutex.synchronize do
            now = Time.local.to_unix_ms
            last_job_time = @last_job_times[queue.name]?

            if last_job_time
              elapsed = now - last_job_time
              sleep_time = min_interval - elapsed

              if sleep_time > 0
                sleep (sleep_time / 1000.0).seconds
              end
            end

            @last_job_times[queue.name] = Time.local.to_unix_ms
          end
        end
      end
    end
  end
end
