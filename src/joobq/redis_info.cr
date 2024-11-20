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
    getter cpu_usage : Float64

    def self.info
      new.info
    end

    def initialize(redis : Redis::PooledClient = RedisStore.instance.redis)
      info = redis.info

      @uptime_in_seconds = info["uptime_in_seconds"].to_i64
      @os = info["os"]
      @uptime_in_days = info["uptime_in_days"].to_i32
      @redis_version = info["redis_version"]
      @maxclients = info["maxclients"].to_i32
      @connected_clients = info["connected_clients"].to_i32
      @used_memory_human = info["used_memory_human"]
      @used_memory_peak_human = info["used_memory_peak_human"]
      @used_memory_peak_perc = info["used_memory_peak_perc"]
      @maxmemory_human = info["maxmemory_human"]
      @total_system_memory_human = info["total_system_memory_human"]
      @used_cpu_sys = info["used_cpu_sys"].to_f64
      @used_cpu_user = info["used_cpu_user"].to_f64
      @instantaneous_input_kbps = info["instantaneous_input_kbps"].to_f64
      @instantaneous_output_kbps = info["instantaneous_output_kbps"].to_f64
      @cpu_usage = ((@used_cpu_sys + @used_cpu_user)/@uptime_in_seconds * 100).round(2)
    end

    def info
      {
        "uptime_in_seconds" => @uptime_in_seconds,
        "os" => @os,
        "uptime_in_days" => @uptime_in_days,
        "redis_version" => @redis_version,
        "maxclients" => @maxclients,
        "connected_clients" => @connected_clients,
        "used_memory_human" => @used_memory_human,
        "used_memory_peak_human" => @used_memory_peak_human,
        "used_memory_peak_perc" => @used_memory_peak_perc,
        "maxmemory_human" => @maxmemory_human,
        "total_system_memory_human" => @total_system_memory_human,
        "used_cpu_sys" => @used_cpu_sys,
        "used_cpu_user" => @used_cpu_user,
        "instantaneous_input_kbps" => @instantaneous_input_kbps,
        "instantaneous_output_kbps" => @instantaneous_output_kbps,
        "cpu_usage" => @cpu_usage,
      }
    end
  end
end
