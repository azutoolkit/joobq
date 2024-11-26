module JoobQ
  struct RedisInfo
    getter uptime_in_seconds : Int64
    getter os : String
    getter uptime_in_days : Int32
    getter redis_version : String
    getter maxclients : Int32
    getter connected_clients : Int32
    getter used_memory_human : String
    getter used_memory_peak_human : String
    getter used_memory_peak_perc : String
    getter maxmemory_human : String
    getter total_system_memory_human : String
    getter used_cpu_sys : Float64
    getter used_cpu_user : Float64
    getter instantaneous_input_kbps : Float64
    getter instantaneous_output_kbps : Float64

    @@prev_used_cpu_sys : Float64 = 0.0
    @@prev_used_cpu_user : Float64 = 0.0
    @@prev_timestamp = Time.local

    def self.info
      new.info
    end

    def initialize(redis : Redis::PooledClient = RedisStore.instance.redis)
      info = redis.info

      @uptime_in_seconds = info.fetch("uptime_in_seconds", 0).to_i64
      @os = info.fetch("os", "")
      @uptime_in_days = info.fetch("uptime_in_days", 0).to_i32
      @redis_version = info.fetch("redis_version", "")
      @maxclients = info.fetch("maxclients", 0).to_i32
      @connected_clients = info.fetch("connected_clients", 0).to_i32
      @used_memory_human = info.fetch("used_memory_human", "")
      @used_memory_peak_human = info.fetch("used_memory_peak_human", "")
      @used_memory_peak_perc = info.fetch("used_memory_peak_perc", "")
      @maxmemory_human = info.fetch("maxmemory_human", "")
      @total_system_memory_human = info.fetch("total_system_memory_human", "")
      @used_cpu_sys = info.fetch("used_cpu_sys", 0.0).to_f64
      @used_cpu_user = info.fetch("used_cpu_user", 0.0).to_f64
      @instantaneous_input_kbps = info.fetch("instantaneous_input_kbps", 0.0).to_f64
      @instantaneous_output_kbps = info.fetch("instantaneous_output_kbps", 0.0).to_f64
    end

    def info
      {
        "uptime_in_seconds"         => @uptime_in_seconds,
        "os"                        => @os,
        "uptime_in_days"            => @uptime_in_days,
        "redis_version"             => @redis_version,
        "maxclients"                => @maxclients,
        "connected_clients"         => @connected_clients,
        "used_memory_human"         => @used_memory_human,
        "used_memory_peak_human"    => @used_memory_peak_human,
        "used_memory_peak_perc"     => @used_memory_peak_perc,
        "maxmemory_human"           => @maxmemory_human,
        "total_system_memory_human" => @total_system_memory_human,
        "used_cpu_sys"              => @used_cpu_sys,
        "used_cpu_user"             => @used_cpu_user,
        "instantaneous_input_kbps"  => @instantaneous_input_kbps,
        "instantaneous_output_kbps" => @instantaneous_output_kbps,
        "cpu_usage"                 => cpu_usage.round(2),
        "average_cpu_usage"         => average_cpu_usage.round(2),
      }
    end

    def cpu_usage
      current_timestamp = Time.local
      delta_cpu_sys = @used_cpu_sys - @@prev_used_cpu_sys
      delta_cpu_user = @used_cpu_user - @@prev_used_cpu_user
      elapsed_time = (current_timestamp - @@prev_timestamp).total_seconds

      # Update previous values
      @@prev_used_cpu_sys = @used_cpu_sys
      @@prev_used_cpu_user = @used_cpu_user
      @@prev_timestamp = Time.local

      if elapsed_time > 0
        ((delta_cpu_sys + delta_cpu_user) / (elapsed_time) * 100).round(2)
      else
        0.0
      end
    end

    def average_cpu_usage
      current_timestamp = Time.local
      elapsed_time = (current_timestamp - @@prev_timestamp).total_seconds

      if elapsed_time > 0
        ((@used_cpu_sys + @used_cpu_user) / (elapsed_time) * 100).round(2)
      else
        0.0
      end
    end
  end
end
