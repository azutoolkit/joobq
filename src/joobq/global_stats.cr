module JoobQ
  module JoobQ
    class GlobalStats
      property total_enqueued : Int64 = 0
      property total_completed : Int64 = 0
      property total_retried : Int64 = 0
      property total_dead : Int64 = 0
      property total_processing : Int64 = 0
      property total_workers : Int32 = 0
      property total_running_workers : Int32 = 0
      property jobs_per_second : Float64 = 0.0
      property errors_per_second : Float64 = 0.0
      property enqueued_per_second : Float64 = 0.0
      property jobs_latency : String = "0s"
      @start_time = Time.monotonic

      property overtime_series : Array(NamedTuple(name: String, type: String, data: Array(NamedTuple(x: String, y: Float64 | Int64)))) =
        [] of NamedTuple(name: String, type: String, data: Array(NamedTuple(x: String, y: Float64 | Int64)))

      def initialize
        @overtime_series << { name: "Enqueued", type: "column", data: [] of NamedTuple(x: String, y: Float64 | Int64) }
        @overtime_series << { name: "Completed", type: "line", data: [] of NamedTuple(x: String, y: Float64 | Int64) }
      end

      def self.calculate_stats(queues)
        @@stats ||= new
        @@stats.not_nil!.calculate_stats(queues)
      end

      def calculate_stats(queues)
        reset
        queues.each do |_, queue|
          info = queue.info
          @total_enqueued += info[:enqueued]
          @total_completed += info[:completed]
          @total_retried += info[:retried]
          @total_dead += info[:dead]
          @total_processing += info[:processing]
          @total_workers += info[:total_workers]
          @total_running_workers += info[:running_workers]
          @jobs_per_second += info[:jobs_per_second]
          @errors_per_second += info[:errors_per_second]
          @enqueued_per_second += info[:enqueued_per_second]
          @jobs_latency += info[:jobs_latency]
        end

        stats
      end

      def reset
        @total_enqueued = 0
        @total_completed = 0
        @total_retried = 0
        @total_dead = 0
        @total_processing = 0
        @total_workers = 0
        @total_running_workers = 0
        @jobs_per_second = 0.0
        @errors_per_second = 0.0
        @enqueued_per_second = 0.0
        @jobs_latency = "0s"
      end

      def stats
        {
          "total_enqueued"        => @total_enqueued,
          "total_completed"       => @total_completed,
          "total_retried"         => @total_retried,
          "total_dead"            => @total_dead,
          "total_processing"      => @total_processing,
          "total_workers"         => @total_workers,
          "total_running_workers" => @total_running_workers,
          "jobs_per_second"       => @jobs_per_second.round(2),
          "errors_per_second"     => @errors_per_second.round(2),
          "enqueued_per_second"   => @enqueued_per_second.round(2),
          "percent_pending"       => percent_of(@total_enqueued-@total_completed, @total_enqueued),
          "percent_processing"    => percent_of(@total_processing, @total_enqueued),
          "percent_completed"     => percent_of(@total_completed, @total_enqueued),
          "percent_retried"       => percent_of(@total_retried, @total_enqueued),
          "percent_dead"          => percent_of(@total_dead, @total_enqueued),
          "overtime_series"       => overtime_series,
        }
      end

      def overtime_series
        enqueued_series =  @overtime_series.first
        completed_series = @overtime_series.last

        current_time = Time.local
        elapsed = Time.monotonic - @start_time
        enqueued_series[:data] << { x: current_time.to_rfc3339, y:  @total_enqueued}
        completed_series[:data] << { x: current_time.to_rfc3339, y: @jobs_per_second.round(2)}

        enqueued_series[:data].shift if enqueued_series[:data].size > 10
        completed_series[:data].shift if completed_series[:data].size > 10

        @start_time = Time.monotonic
        @overtime_series
      end

      def per_second(value, elapsed)
        elapsed.to_f == 0 ? 0.0 : value.to_f / elapsed.to_f
      end

      def percent_of(value, total)
        total.to_f == 0 ? 0.0 : (value.to_f / total.to_f * 100).round(2)
      end
    end
  end
end
