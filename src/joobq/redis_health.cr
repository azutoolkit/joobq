module JoobQ
  # Redis health monitoring and diagnostics
  class RedisHealth
    # Health check interval for monitoring
    HEALTH_CHECK_INTERVAL = 5.seconds

    def initialize(@redis : Redis::PooledClient, @pool_size : Int32, @pool_timeout : Float64)
    end

    # Connection pool health check with detailed metrics
    def health_check : Hash(String, String | Int32 | Bool | Float64)
      start_time = Time.monotonic

      begin
        # Try a simple ping
        @redis.ping
        response_time = (Time.monotonic - start_time).total_milliseconds

        {
          "status"           => "healthy",
          "response_time_ms" => response_time.round(2),
          "pool_size"        => @pool_size,
          "pool_timeout"     => @pool_timeout,
          "connected"        => true,
        }
      rescue ex
        {
          "status"       => "unhealthy",
          "error"        => ex.message || "Unknown error",
          "pool_size"    => @pool_size,
          "pool_timeout" => @pool_timeout,
          "connected"    => false,
        }
      end
    end

    # Get Redis server information
    def server_info : Hash(String, String)
      begin
        info = @redis.info("server")
        {
          "redis_version"     => info["redis_version"]?.to_s || "unknown",
          "redis_mode"        => info["redis_mode"]?.to_s || "unknown",
          "os"                => info["os"]?.to_s || "unknown",
          "arch_bits"         => info["arch_bits"]?.to_s || "unknown",
          "uptime_in_seconds" => info["uptime_in_seconds"]?.to_s || "unknown",
        }
      rescue ex
        {
          "redis_version"     => "unknown",
          "redis_mode"        => "unknown",
          "os"                => "unknown",
          "arch_bits"         => "unknown",
          "uptime_in_seconds" => "unknown",
          "error"             => ex.message || "Failed to get server info",
        }
      end
    end

    # Get memory usage information
    def memory_info : Hash(String, String)
      begin
        info = @redis.info("memory")
        {
          "used_memory"            => info["used_memory"]?.to_s || "unknown",
          "used_memory_human"      => info["used_memory_human"]?.to_s || "unknown",
          "used_memory_peak"       => info["used_memory_peak"]?.to_s || "unknown",
          "used_memory_peak_human" => info["used_memory_peak_human"]?.to_s || "unknown",
          "used_memory_rss"        => info["used_memory_rss"]?.to_s || "unknown",
          "used_memory_rss_human"  => info["used_memory_rss_human"]?.to_s || "unknown",
        }
      rescue ex
        {
          "used_memory"            => "unknown",
          "used_memory_human"      => "unknown",
          "used_memory_peak"       => "unknown",
          "used_memory_peak_human" => "unknown",
          "used_memory_rss"        => "unknown",
          "used_memory_rss_human"  => "unknown",
          "error"                  => ex.message || "Failed to get memory info",
        }
      end
    end

    # Get client information
    def client_info : Hash(String, String)
      begin
        info = @redis.info("clients")
        {
          "connected_clients"          => info["connected_clients"]?.to_s || "unknown",
          "client_longest_output_list" => info["client_longest_output_list"]?.to_s || "unknown",
          "client_biggest_input_buf"   => info["client_biggest_input_buf"]?.to_s || "unknown",
          "blocked_clients"            => info["blocked_clients"]?.to_s || "unknown",
        }
      rescue ex
        {
          "connected_clients"          => "unknown",
          "client_longest_output_list" => "unknown",
          "client_biggest_input_buf"   => "unknown",
          "blocked_clients"            => "unknown",
          "error"                      => ex.message || "Failed to get client info",
        }
      end
    end

    # Comprehensive health report
    def comprehensive_health_report : Hash(String, Hash(String, String))
      {
        "health"    => health_check.transform_values(&.to_s),
        "server"    => server_info,
        "memory"    => memory_info,
        "clients"   => client_info,
        "timestamp" => {"checked_at" => Time.local.to_rfc3339},
      }
    end
  end
end
