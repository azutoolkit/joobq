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
      property avg_jobs_latency : Float64 = 0.0
      property elapsed_time : String = "0s"

      def initialize(@queues = {} of String => BaseQueue)
        calculate_stats
      end

      def calculate_stats
        queues = @queues.values
        @total_enqueued = queues.sum(&.size.to_i64)
        @total_completed = queues.sum(&.completed.get)
        @total_retried = queues.sum(&.retried.get)
        @total_dead = queues.sum(&.dead.get)
        @total_processing = queues.sum(&.busy.get)
        @total_workers = queues.sum(&.total_workers)
        @total_running_workers = queues.sum(&.running_workers)
        @jobs_per_second = queues.sum(&.jobs_per_second)
        @errors_per_second = queues.sum(&.errors_per_second)
        @enqueued_per_second = queues.sum(&.enqueued_per_second)
        @avg_jobs_latency = queues.sum(&.jobs_latency.to_i) / queues.size
        @elapsed_time = (queues.max_of { |q| Time.monotonic - q.start_time } || Time::Span.zero).to_s
      end

      def to_json
        {
          "stats" => {
            "total_enqueued"        => @total_enqueued,
            "total_completed"       => @total_completed,
            "total_retried"         => @total_retried,
            "total_dead"            => @total_dead,
            "total_processing"      => @total_processing,
            "total_workers"         => @total_workers,
            "total_running_workers" => @total_running_workers,
            "jobs_per_second"       => @jobs_per_second,
            "errors_per_second"     => @errors_per_second,
            "enqueued_per_second"   => @enqueued_per_second,
            "avg_jobs_latency"      => @avg_jobs_latency,
            "elapsed_time"          => @elapsed_time,
            "complete_percentage"   => @total_completed.to_f / @total_enqueued.to_f * 100,
            "retried_percentage"    => @total_retried.to_f / @total_enqueued.to_f * 100,
            "dead_percentage"       => @total_dead.to_f / @total_enqueued.to_f * 100,
            "processing_percentage" => @total_processing.to_f / @total_enqueued.to_f * 100,
          },
        }.to_json
      end
    end
  end
end
