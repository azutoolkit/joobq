require "json"

module JoobQ
  # Snapshot of one worker process, as stored in Redis and served by the API.
  struct WorkerInfo
    include JSON::Serializable

    getter id : String
    getter host : String
    getter pid : Int64
    getter version : String
    getter started_at : Int64
    getter status : String
    getter queues : Array(String)
    getter concurrency : Int32
    getter fibers_active : Int32
    getter rss_kb : Int64
    getter cpu_pct : Float64
    getter last_heartbeat : Int64

    def initialize(@id, @host, @pid, @version, @started_at, @status, @queues,
                   @concurrency, @fibers_active, @rss_kb, @cpu_pct, @last_heartbeat)
    end

    def stale?(now : Int64 = Time.utc.to_unix_ms) : Bool
      now - last_heartbeat > WorkerRegistry::TTL.total_milliseconds
    end
  end

  # Publishes this process as a worker: a heartbeat refreshes a TTL'd hash and
  # an index entry, so crashed processes disappear on their own.
  class WorkerRegistry
    Log      = ::Log.for("WORKER_REGISTRY")
    PREFIX   = "joobq:worker:"
    INDEX    = "joobq:workers"
    INTERVAL = 10.seconds
    TTL      = 30.seconds

    getter id : String

    @heartbeat = BackgroundLoop.new("worker_registry")
    @started_at = Time.utc.to_unix_ms
    @last_sample = Time.instant
    @last_cpu : Float64

    def initialize(@store : RedisStore = RedisStore.instance,
                   @id : String = "#{System.hostname}:#{Process.pid}")
      @redis = @store.redis
      @last_cpu = cpu_seconds
    end

    def start : Nil
      @heartbeat.start do
        beat
        follow_desired_concurrency
        trim_events
        INTERVAL
      end
    end

    def stop : Nil
      @heartbeat.stop
      Latency.stop
      @redis.pipelined do |pipe|
        pipe.del(key)
        pipe.zrem(INDEX, @id)
      end
    end

    def beat(status : String = "running") : Nil
      now = Time.utc.to_unix_ms
      @redis.pipelined do |pipe|
        pipe.set(key, snapshot(status, now).to_json, ex: TTL.total_seconds.to_i)
        pipe.zadd(INDEX, now, @id)
      end
    end

    # Live workers, newest heartbeat first. Entries whose TTL lapsed are pruned.
    def self.all(redis : Redis::PooledClient = RedisStore.instance.redis) : Array(WorkerInfo)
      cutoff = Time.utc.to_unix_ms - TTL.total_milliseconds.to_i64
      redis.zremrangebyscore(INDEX, "-inf", cutoff)
      ids = redis.zrevrange(INDEX, 0, -1).map(&.to_s)
      ids.compact_map do |id|
        json = redis.get(PREFIX + id) || next
        WorkerInfo.from_json(json)
      rescue ex : JSON::ParseException | JSON::SerializableError
        Log.warn &.emit("Ignoring an unreadable worker entry", worker: id, error: ex.message)
        nil
      end
    end

    # Follows worker counts an operator set after this process started; a
    # redeploy with new config therefore wins over an older operator choice.
    def follow_desired_concurrency : Nil
      JoobQ.queues.each_value do |queue|
        desired = @store.desired_concurrency(queue.name)
        next unless desired && desired[:set_at] > @started_at && desired[:count] != queue.total_workers

        queue.apply_concurrency(desired[:count])
      rescue ex
        Log.warn &.emit("Could not apply desired concurrency", queue: queue.name, error: ex.message)
      end
    end

    # A failed trim must not stop the heartbeat: the stream just stays a little larger until the next beat.
    private def trim_events : Nil
      RedisEventSink.trim_to_bytes(@redis)
    rescue ex
      Log.warn &.emit("Could not trim the event stream", error: ex.message)
    end

    private def key : String
      PREFIX + @id
    end

    private def snapshot(status : String, now : Int64) : WorkerInfo
      queues = JoobQ.queues.values
      WorkerInfo.new(
        id: @id, host: System.hostname, pid: Process.pid.to_i64, version: VERSION,
        started_at: @started_at, status: status,
        queues: JoobQ.queues.keys,
        concurrency: queues.sum(&.total_workers),
        fibers_active: queues.sum(&.running_workers),
        rss_kb: rss_kb, cpu_pct: cpu_pct, last_heartbeat: now)
    end

    # Resident set size (kB) from /proc/self/status (Linux); 0 where unavailable.
    private def rss_kb : Int64
      line = File.read_lines("/proc/self/status").find(&.starts_with?("VmRSS:"))
      line ? line.split[1].to_i64 : 0_i64
    rescue File::Error
      0_i64
    end

    private def cpu_seconds : Float64
      times = Process.times
      times.utime + times.stime
    end

    # CPU use of this process since the previous sample, as a percentage of one core.
    private def cpu_pct : Float64
      cpu = cpu_seconds
      now = Time.instant
      elapsed = (now - @last_sample).total_seconds
      pct = elapsed > 0 ? (cpu - @last_cpu) / elapsed * 100 : 0.0
      @last_cpu = cpu
      @last_sample = now
      pct.round(1)
    end
  end
end
