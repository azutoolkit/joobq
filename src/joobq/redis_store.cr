require "digest/sha1"

module JoobQ
  class RedisStore < Store
    DELAYED_SET      = "joobq:delayed_jobs"
    private DEAD_LETTER      = "joobq:dead_letter"
    private PROCESSING_QUEUE = "joobq:processing"
    private BLOCKING_TIMEOUT = 0.5

    # Each process claims into its own processing list, `joobq:processing:<queue>:<owner>`, and publishes a liveness
    # heartbeat in the `joobq:processing:owners` sorted set (score = last beat, ms). Recovery returns a processing
    # list to its queue only when its owner's heartbeat has lapsed, so a live process's in-flight jobs are never
    # moved out from under it. `joobq:processing:<queue>` with no owner suffix is the shared list older (0.5)
    # workers claimed into; it is migrated once no live owner remains. The heartbeat is independent of the optional
    # `WorkerRegistry`, so recovery is correct whether or not a process publishes the richer worker snapshot.
    # Not under the `joobq:processing:` prefix, so the processing-list SCANs never match it, and a queue
    # literally named "owners" does not collide with it.
    OWNERS     = "joobq:processing-owners"
    private OWNER_TTL  = 30.seconds
    private OWNER_BEAT = 10.seconds

    # The configured store when it is a RedisStore, so classes that default to it talk to the same Redis as the
    # queues. Only before any configuration exists (or for another Store) is a store built from ENV.
    @@instance : RedisStore? = nil

    def self.instance : RedisStore
      JoobQ.configured_store?.as?(RedisStore) || (@@instance ||= from_env)
    end

    # The store the environment asks for: REDIS_URL (with REDIS_TLS_VERIFY and REDIS_CA_FILE) when it is set, otherwise
    # REDIS_HOST, REDIS_PORT and REDIS_PASS. A REDIS_URL that cannot be used raises `RedisEndpoint::Invalid` rather
    # than falling back to a plain connection to REDIS_HOST.
    def self.from_env : RedisStore
      url = ENV["REDIS_URL"]?.presence
      return new unless url

      new(url: url, verify: verify_setting(ENV["REDIS_TLS_VERIFY"]?, "REDIS_TLS_VERIFY") != false,
        ca_file: ENV["REDIS_CA_FILE"]?.presence)
    end

    # `true`/`1`/`yes`/`on` and `false`/`0`/`no`/`off` (any case); nil when `value` is unset or empty. Anything else
    # raises, because a misspelt "off" would otherwise be read as "on".
    def self.verify_setting(value : String?, name : String) : Bool?
      word = value.try(&.strip.downcase).presence
      return unless word
      return true if %w[true 1 yes on].includes?(word)
      return false if %w[false 0 no off].includes?(word)

      raise RedisEndpoint::Invalid.new("#{name} must be true or false")
    end

    # The parsed URL of a store made with `url:`; nil for one made with host and port.
    getter endpoint : RedisEndpoint? = nil

    getter redis : Redis::PooledClient
    getter host : String
    getter port : Int32
    getter pool_size : Int32
    getter pool_timeout : Float64
    getter health : RedisHealth
    getter pipeline : RedisPipeline
    getter metrics : RedisMetrics

    # Identifies this process's processing lists and heartbeat. Stable for the life of the process; a crashed process
    # that restarts gets a new pid and so a new id, which leaves its old list orphaned for recovery. Settable so a
    # spec can act as several processes against one Redis.
    getter owner_id : String = "#{System.hostname}:#{Process.pid}"

    # Keeps the batch-cleanup pipeline on the same owner id, so a spec that poses as another process cleans up the
    # list it claimed into.
    def owner_id=(id : String) : String
      @pipeline.owner_id = id
      @owner_id = id
    end

    @owner_heartbeat = BackgroundLoop.new("processing_owner")
    @list_move_checked = Atomic(Bool).new(false)
    # Endpoint and timeouts kept so a queue dispatcher can mint its own dedicated blocking connection (a BLMOVE
    # holds its connection for the block, so it must not take one from the shared pool).
    @blocking_endpoint : RedisEndpoint? = nil
    @connect_timeout : Time::Span = 5.seconds
    @command_timeout : Time::Span = 5.seconds

    def initialize(@host : String = ENV.fetch("REDIS_HOST", "localhost"),
                   @port : Int32 = ENV.fetch("REDIS_PORT", "6379").to_i,
                   @password : String? = ENV["REDIS_PASS"]?,
                   @pool_size : Int32 = ENV.fetch("REDIS_POOL_SIZE", "500").to_i,
                   @pool_timeout : Float64 = ENV.fetch("REDIS_POOL_TIMEOUT", "2.0").to_f64,
                   connect_timeout : Time::Span = ENV.fetch("REDIS_CONNECT_TIMEOUT", "5.0").to_f64.seconds,
                   command_timeout : Time::Span = ENV.fetch("REDIS_COMMAND_TIMEOUT", "5.0").to_f64.seconds,
                   operation_timeout : Time::Span = ENV.fetch("REDIS_OPERATION_TIMEOUT", "5.0").to_f64.seconds)
      raise ArgumentError.new("Redis timeouts must be positive") if connect_timeout <= Time::Span.zero || command_timeout <= Time::Span.zero
      @blocking_endpoint = RedisEndpoint.new(@host, @port, password: @password)
      @connect_timeout = connect_timeout
      @command_timeout = command_timeout
      @redis = RedisPool.new(@blocking_endpoint.not_nil!,
        @pool_size, @pool_timeout, connect_timeout, command_timeout, operation_timeout)

      # Initialize specialized components
      @health = RedisHealth.new(@redis, @pool_size, @pool_timeout)
      @pipeline = RedisPipeline.new(@redis)
      @metrics = RedisMetrics.new(@redis)

      # Log connection pool configuration
      Log.info &.emit("Redis store initialized",
        host: @host,
        port: @port,
        pool_size: @pool_size,
        pool_timeout: @pool_timeout
      )
    end

    # Connects to the server a `redis://` or `rediss://` URL names (see `RedisEndpoint`): as an ACL user when the
    # URL has a user name, over TLS for `rediss`, on the database in its path. `verify` and `ca_file` control how
    # the server certificate is checked.
    def initialize(*, url : String, pool_size : Int32 = ENV.fetch("REDIS_POOL_SIZE", "500").to_i,
                   pool_timeout : Float64 = ENV.fetch("REDIS_POOL_TIMEOUT", "2.0").to_f64,
                   verify : Bool = true, ca_file : String? = nil,
                   connect_timeout : Time::Span = ENV.fetch("REDIS_CONNECT_TIMEOUT", "5.0").to_f64.seconds,
                   command_timeout : Time::Span = ENV.fetch("REDIS_COMMAND_TIMEOUT", "5.0").to_f64.seconds,
                   operation_timeout : Time::Span = ENV.fetch("REDIS_OPERATION_TIMEOUT", "5.0").to_f64.seconds)
      endpoint = RedisEndpoint.parse(url, verify, ca_file)
      @endpoint = endpoint
      @blocking_endpoint = endpoint
      @connect_timeout = connect_timeout
      @command_timeout = command_timeout
      @host = endpoint.host
      @port = endpoint.port
      @password = nil # the endpoint's clients hold the credentials; the store keeps none
      @pool_size = pool_size
      @pool_timeout = pool_timeout
      @redis = RedisPool.new(endpoint, pool_size, pool_timeout, connect_timeout, command_timeout, operation_timeout)

      @health = RedisHealth.new(@redis, @pool_size, @pool_timeout)
      @pipeline = RedisPipeline.new(@redis)
      @metrics = RedisMetrics.new(@redis)

      Log.info &.emit("Redis store initialized",
        endpoint: endpoint.to_s,
        pool_size: @pool_size,
        pool_timeout: @pool_timeout
      )
    end

    # Closes current connections for either constructor. Later commands reconnect.
    def close : Nil
      @redis.as?(RedisPool).try(&.close)
    end

    # Host, port and pool only: the default `inspect` would print the password this store was given.
    def inspect(io : IO) : Nil
      io << "#<" << self.class.name << ' ' << host << ':' << port << '>'
    end

    # Connection pool health check with detailed metrics
    def health_check : Hash(String, String | Int32 | Bool | Float64)
      health_data = @health.health_check
      health_data["pipeline_stats"] = RedisPipeline.pipeline_stats.to_json
      health_data
    end

    def reset : Nil
      redis.flushdb
    end

    def clear_queue(queue_name : String) : Nil
      redis.del(queue_name)
    end

    # Optimized method to clear multiple queues in a single pipeline
    def clear_queues_batch(queue_names : Array(String)) : Nil
      @pipeline.clear_queues_batch(queue_names)
    end

    def delete_job(job : String) : Nil
      parsed_job = JSON.parse(job)
      queue_name = parsed_job["queue"]?.try(&.as_s)
      return unless queue_name

      # Remove the job from this process's list and the legacy shared list (all occurrences)
      redis.lrem(processing_queue(queue_name), 0, job)
      redis.lrem(legacy_processing_queue(queue_name), 0, job)

      Log.debug &.emit("Job deleted",
        queue: queue_name,
        job_data_length: job.size
      )
    rescue ex
      Log.error &.emit("Error deleting job", error: ex.message)
    end

    def enqueue(job : Job) : String
      redis.rpush job.queue, job.to_json
      Events.emit("job.enqueued") { {jid: job.jid.to_s, queue: job.queue} }

      Log.debug &.emit("Job enqueued", job_id: job.jid.to_s, queue: job.queue)
      job.jid.to_s
    end

    def enqueue_batch(jobs : Array(Job), batch_size : Int32 = 1000, *, json_sizes : Array(Int32)? = nil) : Nil
      raise "Batch size must be greater than 0" if batch_size <= 0
      raise "Batch size must be less than or equal to 1000" if batch_size > 1000

      if sizes = json_sizes
        raise ArgumentError.new("json_sizes must contain one nonnegative capacity per job") unless sizes.size == jobs.size && sizes.all? { |size| size >= 0 }
      end

      return if jobs.empty?

      start_time = Time.instant
      total_enqueued = 0

      begin
        jobs.each_slice(batch_size) do |batch_jobs|
          redis.pipelined do |pipe|
            batch_jobs.each_with_index do |job, index|
              payload = if sizes = json_sizes
                          String.build(sizes[total_enqueued + index]) { |io| job.to_json(io) }
                        else
                          job.to_json
                        end
              pipe.rpush job.queue, payload
            end
          end
          total_enqueued += batch_jobs.size
          batch_jobs.each { |job| Events.emit("job.enqueued") { {jid: job.jid.to_s, queue: job.queue} } }
        end

        duration = Time.instant - start_time
        Log.info &.emit("Batch enqueue successful",
          jobs_count: total_enqueued,
          duration_ms: duration.total_milliseconds.round(2),
          jobs_per_second: (total_enqueued / duration.total_seconds).round(2)
        )
      rescue ex
        Log.error &.emit("Batch enqueue failed",
          total_jobs: jobs.size,
          enqueued: total_enqueued,
          error: ex.message,
          error_class: ex.class.name
        )
        raise ex
      end
    end

    # Claims the oldest job: producers RPUSH to the tail, so taking the head (BLMOVE ... LEFT LEFT, Redis 6.2+) gives
    # first-in-first-out order. The job moves to the head of the processing list in the same atomic step, so a crash
    # after the claim leaves it there for `move_job_back_to_queue`. Blocks up to BLOCKING_TIMEOUT when the queue is empty.
    def dequeue(queue_name : String, klass : Class) : String?
      processing_key = processing_queue(queue_name)

      # The shard has no `blmove`; the raw command is sent as is.
      if job_data = redis.command(["BLMOVE", queue_name, processing_key, "LEFT", "LEFT", BLOCKING_TIMEOUT.to_s]).as?(String)
        Log.debug &.emit("Job dequeued", queue: queue_name, job_data_length: job_data.size)
        return job_data
      end

      nil
    rescue ex
      Log.error &.emit("Error dequeuing job", queue: queue_name, error: ex.message)
      nil
    end

    # A dedicated, non-pooled connection for a queue dispatcher's blocking BLMOVE. The command timeout is kept well
    # above the block timeout so the block itself never trips it; closing the connection interrupts a blocked call.
    def blocking_connection : RedisClient
      endpoint = @blocking_endpoint || raise "blocking connection needs an endpoint"
      timeout = {@command_timeout, (BLOCKING_TIMEOUT + 1.0).seconds}.max
      RedisClient.new(endpoint, connect_timeout: @connect_timeout, command_timeout: timeout)
    end

    # Claims the oldest job, blocking up to BLOCKING_TIMEOUT, on the caller's dedicated connection (not the pool).
    # Claims into this process's own processing list, exactly like `dequeue`, so recovery is unchanged. Returns nil
    # only on an empty queue (the block timed out). A connection error — including the close used to interrupt the
    # block on stop — is raised, not swallowed, so the dispatcher can tell "empty" from "Redis is down" and back off
    # on the latter instead of reconnect-storming.
    def blocking_claim(queue_name : String, connection : Redis) : String?
      connection.command(["BLMOVE", queue_name, processing_queue(queue_name), "LEFT", "LEFT", BLOCKING_TIMEOUT.to_s]).as?(String)
    end

    # Claims up to `batch_size` jobs from the head of the queue without blocking, oldest first (the order the replies
    # come back in). Each LMOVE is atomic on its own, like the single claim; an empty queue answers nil.
    def dequeue_batch(queue_name : String, klass : Class, batch_size : Int32 = 10) : Array(String)
      processing_key = processing_queue(queue_name)
      jobs = [] of String

      redis.pipelined do |pipe|
        batch_size.times do
          pipe.command(["LMOVE", queue_name, processing_key, "LEFT", "LEFT"])
        end
      end.each do |result|
        if result && !result.to_s.empty?
          jobs << result.to_s
        end
      end

      Log.debug &.emit("Batch dequeued jobs", queue: queue_name, count: jobs.size)
      jobs
    rescue ex
      Log.error &.emit("Error batch dequeuing jobs", queue: queue_name, error: ex.message)
      [] of String
    end

    # Claims use LMOVE/BLMOVE (Redis 6.2+). On an older server every claim would fail and be logged while the queue
    # grows, so a queue refuses to start instead. Asks the server itself (LMOVE on a key that does not exist moves
    # nothing) rather than parsing a version string, so Redis-compatible servers that implement the command pass.
    def ensure_list_move_support! : Nil
      return if @list_move_checked.get
      begin
        redis.command(["LMOVE", "joobq:lmove-probe", "joobq:lmove-probe", "LEFT", "LEFT"])
      rescue ex : Redis::Error
        # anything else (a timeout, NOPERM, READONLY) is not about the version and is raised as it is
        raise ex unless ex.message.try(&.downcase.includes?("unknown command"))
        raise ArgumentError.new("JoobQ needs Redis 6.2 or newer (LMOVE/BLMOVE): #{ex.message}")
      end
      @list_move_checked.set(true)
    end

    # Starts this process's liveness heartbeat (idempotent, process-wide). `Queue#start` calls it before claiming,
    # so every processing list a 0.6 process owns has a live heartbeat while the process runs.
    def start_owner_heartbeat : Nil
      beat_owner
      @owner_heartbeat.start do
        beat_owner
        OWNER_BEAT
      end
    end

    # Stops the heartbeat and drops this process's owner entry, so recovery on another process can reclaim this
    # process's lists at once rather than waiting out the TTL. A crash skips this and the entry lapses after the TTL.
    def stop_owner_heartbeat : Nil
      @owner_heartbeat.stop
      redis.zrem(OWNERS, @owner_id)
    rescue ex
      Log.warn &.emit("Could not drop the processing owner entry", owner: @owner_id, error: ex.message)
    end

    # The Redis server clock, in milliseconds, so every process's heartbeat and every reader's TTL cutoff are on one
    # clock: a process is never judged dead because another node's wall clock runs ahead of it.
    def redis_now_ms : Int64
      parts = redis.command(["TIME"]).as(Array)
      (parts[0].as(String).to_i64 * 1000) + (parts[1].as(String).to_i64 // 1000)
    end

    def beat_owner : Nil
      redis.zadd(OWNERS, redis_now_ms, @owner_id)
    end

    # Owner ids whose heartbeat is within the TTL. Lapsed entries are pruned as they are read. Liveness is scored by
    # the Redis clock, so recovery does not depend on the worker and reaper clocks agreeing. A process paused (GC,
    # starvation) longer than OWNER_TTL can still be judged dead and have its jobs recovered, so jobs stay idempotent.
    def live_owners : Set(String)
      cutoff = redis_now_ms - OWNER_TTL.total_milliseconds.to_i64
      redis.zremrangebyscore(OWNERS, "-inf", cutoff)
      redis.zrange(OWNERS, 0, -1).map(&.as(String)).to_set
    end

    # Drains a processing list to the head of its queue, oldest claim first, in one atomic script, and returns the
    # count. Each claim pushed the job onto the head of its processing list (BLMOVE/LMOVE ... LEFT LEFT, and the old
    # BRPOPLPUSH too), so moving head to head preserves claim order: the recovered jobs run next, before the jobs
    # still waiting.
    # Moves up to ARGV[1] jobs from the head of a (dead owner's) processing list to the head of its queue, and
    # returns how many it moved. Bounded so a huge leftover list does not block single-threaded Redis in one script;
    # the caller loops until a short batch signals the list is empty. Nothing else claims from a dead owner's list,
    # so order is preserved across batches.
    RECOVER_PROCESSING = <<-LUA
      local n = 0
      local limit = tonumber(ARGV[1])
      while n < limit and redis.call('LMOVE', KEYS[1], KEYS[2], 'LEFT', 'LEFT') do
        n = n + 1
      end
      return n
    LUA

    RECOVER_BATCH = 1000

    def drain_processing_list(list_key : String, queue_name : String) : Int64
      moved = 0_i64
      loop do
        count = redis.eval(RECOVER_PROCESSING, [list_key, queue_name], [RECOVER_BATCH.to_s]).as(Int64)
        moved += count
        break if count < RECOVER_BATCH
      end
      moved
    end

    # The processing-list keys that belong to `queue_name`: one per owner (`...:<queue>:<owner>`) plus the shared
    # legacy list (`...:<queue>`) older workers used. A SCAN by prefix also matches another queue whose name starts
    # with this one, so each key is checked against the two exact shapes.
    def processing_lists(queue_name : String) : Array(String)
      prefix = "#{PROCESSING_QUEUE}:#{queue_name}"
      owned_prefix = "#{prefix}:"
      found = [] of String
      cursor = 0_i64
      loop do
        result = redis.scan(cursor, match: "#{prefix}*", count: 100)
        cursor = result[0].as(String).to_i64
        result[1].as(Array).each do |key|
          key_str = key.as(String)
          found << key_str if key_str == prefix || key_str.starts_with?(owned_prefix)
        end
        break if cursor == 0
      end
      found
    end

    # Returns the jobs of crashed or stopped processes to the head of their queue, in claim order, and deletes the
    # drained list. A processing list is reclaimed only when its owner's heartbeat has lapsed (`live_owners`), so a
    # running process's in-flight jobs are never moved. `include_self` drains this process's own list too, which is
    # safe at start-up (no worker of this process is claiming yet) but never from the periodic reaper, where this
    # process is live and working. The shared legacy list (no owner) is migrated only when no owner is live at all,
    # the first 0.6 process into an otherwise-drained cluster; stop 0.5 workers first (see the CHANGELOG). Returns
    # how many jobs were moved.
    def recover_orphaned_processing(queue_name : String, include_self : Bool = false) : Int64
      live = live_owners
      legacy = "#{PROCESSING_QUEUE}:#{queue_name}"
      moved = 0_i64
      processing_lists(queue_name).each do |list_key|
        if list_key == legacy
          # Migrate the pre-0.6 shared list only when no OTHER process is live to claim from it (this process does
          # not claim into the legacy list). Stop 0.5 workers first: they do not register a heartbeat, so a live one
          # cannot be seen here (see the CHANGELOG upgrade note).
          others = live.dup
          others.delete(@owner_id)
          next unless others.empty?
        else
          owner = list_key.lchop("#{legacy}:")
          if owner == @owner_id
            # This process's own list: drained only on an explicit restart recovery, never a live reaper pass.
            next unless include_self
          else
            # Another process's list: reclaimed only once its heartbeat has lapsed.
            next if live.includes?(owner)
          end
        end
        # Drain only; Redis removes a list once it is empty. A separate DEL could destroy a job a (wrongly declared
        # dead) owner pushed between the drain and the delete, so it is not issued.
        moved += drain_processing_list(list_key, queue_name)
      rescue ex
        Log.error &.emit("Could not recover a processing list", list: list_key, queue: queue_name, error: ex.message)
      end
      Log.info &.emit("Returned stranded jobs to the head of their queue", queue: queue_name, count: moved) if moved > 0
      moved
    end

    # Reclaims the queue's orphaned (dead-owner) processing lists; never touches a live process's list. `Queue#start`
    # passes `include_self: true` to also clear a previous incarnation's leftovers before this process claims. True
    # when at least one job was moved; false when none, or when Redis failed (logged). Operate this on a live system
    # only to recover crashed workers: it cannot take a job a live worker still holds.
    def move_job_back_to_queue(queue_name : String, include_self : Bool = false) : Bool
      recover_orphaned_processing(queue_name, include_self) > 0
    rescue ex
      Log.error &.emit("Could not return stranded jobs to their queue", queue: queue_name, error: ex.message)
      false
    end

    # Scored by time of death like every other dead-letter writer, so entries sort
    # and age consistently; `expiration_time` is kept for the Store interface.
    def mark_as_dead(job : Job, expiration_time : Int64) : Nil
      DeadLetterQueue.add(redis, Time.utc.to_unix_ms, [job.to_json])
    end

    def schedule(job : Job, delay_in_ms : Int64, delay_set : String = DELAYED_SET) : Nil
      redis.zadd delay_set, delay_in_ms, job.to_json
    end

    def schedule_job(job : String, schedule_time : Int64) : Nil
      redis.zadd DELAYED_SET, schedule_time, job
    end

    TAKE_DUE = <<-LUA
      local jobs = redis.call('ZRANGEBYSCORE', KEYS[1], 0, ARGV[1], 'LIMIT', 0, ARGV[2])
      for _, job in ipairs(jobs) do
        redis.call('ZREM', KEYS[1], job)
      end
      return jobs
    LUA

    def fetch_due_jobs(
      current_time = Time.local,
      delay_set : String = DELAYED_SET,
      limit : Int32 = 50,
      remove : Bool = true,
    ) : Array(String)
      score = current_time.to_unix_ms
      unless remove
        return redis.zrangebyscore(delay_set, 0, score, with_scores: false, limit: [0, limit]).map(&.as(String))
      end

      # Read and remove exactly the same members in one step: removing "everything due" after reading `limit` of
      # them would drop the rest unseen.
      redis.eval(TAKE_DUE, [delay_set], [score.to_s, limit.to_s]).as(Array).map(&.as(String))
    end

    def queue_size(queue_name : String) : Int64
      redis.llen(queue_name)
    end

    def set_size(set_name : String) : Int64
      redis.zcard(set_name)
    end

    # Optimized batch queue sizes to reduce connection overhead
    def queue_sizes_batch(queue_names : Array(String)) : Hash(String, Int64)
      @pipeline.queue_sizes_batch(queue_names)
    end

    # Optimized batch set sizes to reduce connection overhead
    def set_sizes_batch(set_names : Array(String)) : Hash(String, Int64)
      @pipeline.set_sizes_batch(set_names)
    end

    # Takes the job off whichever of this process's processing lists holds it (its own owner list, or the legacy
    # shared list a seeded or pre-0.6 job sits in) and pushes it to the tail of the queue. KEYS: self list, legacy
    # list, queue.
    REQUEUE = <<-LUA
      if redis.call('LREM', KEYS[1], 1, ARGV[1]) == 1 then
        redis.call('RPUSH', KEYS[3], ARGV[1])
        return 1
      end
      if redis.call('LREM', KEYS[2], 1, ARGV[1]) == 1 then
        redis.call('RPUSH', KEYS[3], ARGV[1])
        return 1
      end
      return 0
    LUA

    # Puts a claimed job back at the tail of its queue (behind the waiting jobs), in one step: it is taken off the
    # processing list and pushed, or (when it is no longer there, e.g. another process reclaimed it) nothing happens.
    # Not counted as processed. Used for a job bounced for missing encryption keys, which should not come straight
    # back.
    def requeue_from_processing(job_json : String, queue_name : String) : Bool
      redis.eval(REQUEUE, [processing_queue(queue_name), legacy_processing_queue(queue_name), queue_name], [job_json]) == 1
    end

    # `REQUEUE` to the head of the queue, for many jobs in one script. KEYS are (self list, legacy list, queue) per
    # entry, ARGV the jobs, each taken off whichever list holds it and LPUSHed in turn (so the last entry ends up at
    # the head). An entry whose commands fail (a key of the wrong type, say) is skipped inside the script, so one bad
    # entry neither stops the others nor produces an error reply; a pipeline would raise at the first error reply and
    # leave the connection with unread replies.
    REQUEUE_MANY = <<-LUA
      local n = 0
      for i = 1, #ARGV do
        local ok, removed = pcall(redis.call, 'LREM', KEYS[3 * i - 2], 1, ARGV[i])
        if not (ok and removed == 1) then
          ok, removed = pcall(redis.call, 'LREM', KEYS[3 * i - 1], 1, ARGV[i])
        end
        if ok and removed == 1 then
          if pcall(redis.call, 'LPUSH', KEYS[3 * i], ARGV[i]) then n = n + 1 end
        end
      end
      return n
    LUA

    REQUEUE_BATCH = 100

    private def requeue_keys(queue_name : String) : Array(String)
      [processing_queue(queue_name), legacy_processing_queue(queue_name), queue_name]
    end

    # Returns jobs abandoned at shutdown, given as {queue, job} pairs in claim order, to the head of their queues so
    # they run next, in that order; returns how many were put back. Each job is taken off this process's own
    # processing list (or the legacy shared list) and skipped if it is no longer there. The entries are pushed last
    # to first (each push goes in front of the one before), one script per hundred; if a script itself fails, its
    # entries are tried one by one and a failing one is logged and skipped.
    def requeue_many_from_processing(entries : Array({String, String})) : Int32
      put_back = 0
      entries.reverse.each_slice(REQUEUE_BATCH) do |batch|
        begin
          keys = batch.flat_map { |(queue_name, _)| requeue_keys(queue_name) }
          put_back += redis.eval(REQUEUE_MANY, keys, batch.map(&.last)).as(Int).to_i
        rescue ex
          Log.error &.emit("Batch requeue failed, requeuing one by one", error: ex.message)
          batch.each do |(queue_name, job_json)|
            put_back += 1 if redis.eval(REQUEUE_MANY, requeue_keys(queue_name), [job_json]) == 1
          rescue ex2
            Log.error &.emit("Could not requeue a job", queue: queue_name, error: ex2.message)
          end
        end
      end
      put_back
    end

    # Removes a finished job from the processing list and counts it as processed
    def cleanup_job(job_json : String, queue_name : String) : Nil
      redis.pipelined do |pipe|
        # Remove the job from this process's list (and the legacy shared list, for a migrated or seeded job)
        pipe.lrem(processing_queue(queue_name), 0, job_json)
        pipe.lrem(legacy_processing_queue(queue_name), 0, job_json)

        # Update statistics
        pipe.hincrby("joobq:stats:processed", queue_name, 1)
        pipe.hincrby("joobq:stats:total_processed", "global", 1)
      end

      Log.debug &.emit("Job cleanup successful",
        queue: queue_name,
        job_id: logging_job_id(job_json)
      )
    rescue ex
      Log.error &.emit("Error cleaning up job",
        queue: queue_name,
        error: ex.message
      )
    end

    # Batch job cleanup for high performance
    def cleanup_jobs_batch(job_jsons : Array(String), queue_name : String) : Nil
      @pipeline.cleanup_jobs_batch(job_jsons, queue_name)
    end

    # Mark job as completed with statistics
    def mark_job_completed(job_json : String, queue_name : String) : Nil
      redis.pipelined do |pipe|
        # Remove the job from this process's list (and the legacy shared list, for a migrated or seeded job)
        pipe.lrem(processing_queue(queue_name), 0, job_json)
        pipe.lrem(legacy_processing_queue(queue_name), 0, job_json)

        # Update completion statistics
        pipe.hincrby("joobq:stats:completed", queue_name, 1)
        pipe.hincrby("joobq:stats:total_completed", "global", 1)
        pipe.hincrby("joobq:stats:processed", queue_name, 1)
        pipe.hincrby("joobq:stats:total_processed", "global", 1)
      end

      Log.debug &.emit("Job marked as completed",
        queue: queue_name,
        job_id: logging_job_id(job_json)
      )
    rescue ex
      Log.error &.emit("Error marking job as completed",
        queue: queue_name,
        error: ex.message
      )
    end

    # Called only inside lazy debug log blocks; normal completion never parses a second JSON tree.
    private def logging_job_id(job_json : String) : String
      JSON.parse(job_json)["jid"]?.try(&.as_s) || "unknown"
    rescue
      "unknown"
    end

    # A page of the waiting jobs, the next to run first (workers claim from the head of the list).
    def list_jobs(queue_name : String, page_number : Int32 = 1, page_size : Int32 = 200) : Array(String)
      start_index = (page_number - 1) * page_size
      end_index = start_index + page_size - 1
      redis.lrange(queue_name, start_index, end_index).map &.as(String)
    end

    def list_sorted_set_jobs(set_name : String, page_number : Int32 = 1, page_size : Int32 = 200) : Array(String)
      start_index = (page_number - 1) * page_size
      end_index = start_index + page_size - 1
      redis.zrange(set_name, start_index, end_index).map &.as(String)
    end

    # Queue metrics structure for batch collection
    struct QueueMetrics
      include JSON::Serializable
      getter queue_size : Int64
      getter processing_size : Int64
      getter failed_count : Int64
      getter dead_letter_count : Int64
      getter processed_count : Int64

      def initialize(@queue_size : Int64, @processing_size : Int64,
                     @failed_count : Int64, @dead_letter_count : Int64,
                     @processed_count : Int64)
      end
    end

    # Get queue metrics for multiple queues using pipelining
    def get_queue_metrics_pipelined(queue_names : Array(String)) : Hash(String, QueueMetrics)
      metrics = {} of String => QueueMetrics

      if queue_names.empty?
        return metrics
      end

      # Process results (Redis pipelined returns results in order)
      results = redis.pipelined do |pipe|
        queue_names.each do |queue_name|
          pipe.llen(queue_name)                          # Queue size
          pipe.llen(processing_queue(queue_name))        # Processing size
          pipe.zcard("#{queue_name}:failed")             # Failed count
          pipe.zcard("#{queue_name}:dead_letter")        # Dead letter count
          pipe.hget("joobq:stats:processed", queue_name) # Processed count
        end
      end

      # Parse results into metrics
      queue_names.each_with_index do |queue_name, queue_index|
        base_index = queue_index * 5
        queue_size = results[base_index].as(Int64)
        # Across every owner of the queue, not only this process's list (the pipelined llen above)
        processing_size = processing_queue_size(queue_name)
        failed_count = results[base_index + 2].as(Int64)
        dead_letter_count = results[base_index + 3].as(Int64)
        processed_str = results[base_index + 4]
        processed_count = processed_str ? processed_str.as(String).to_i64 : 0i64

        metrics[queue_name] = QueueMetrics.new(
          queue_size, processing_size, failed_count, dead_letter_count, processed_count
        )
      end

      metrics
    rescue ex
      Log.error &.emit("Error collecting queue metrics", queue_count: queue_names.size, error: ex.message)
      {} of String => QueueMetrics
    end

    # Get metrics for a single queue
    def get_queue_metrics(queue_name : String) : QueueMetrics
      get_queue_metrics_pipelined([queue_name])[queue_name]? || QueueMetrics.new(0, 0, 0, 0, 0)
    end

    # Get metrics for all configured queues using pipelining
    def get_all_queue_metrics : Hash(String, QueueMetrics)
      queue_names = JoobQ.config.queues.keys
      get_queue_metrics_pipelined(queue_names)
    end

    # Optimized connection reuse for statistics collection
    def collect_statistics_batch : Hash(String, Int64)
      @metrics.collect_statistics_batch
    end

    def processing_list(pattern : String = "#{PROCESSING_QUEUE}:*", limit : Int32 = 100) : Array(String)
      processing_list_paginated(0, limit, pattern)
    end

    # Optimized processing jobs list with batch operations
    def processing_list_paginated(offset : Int32, limit : Int32, pattern : String = "#{PROCESSING_QUEUE}:*") : Array(String)
      jobs_collected = [] of String
      current_offset = 0
      target_offset = offset

      # Step 1: Use SCAN to get processing queue keys
      cursor = 0_i64
      processing_keys = [] of String

      loop do
        result = redis.scan(cursor, match: pattern, count: 100)
        cursor = result[0].as(String).to_i64
        keys = result[1].as(Array)

        keys.each do |key|
          # Every processing list, per-owner (`...:<queue>:<owner>`) and legacy (`...:<queue>`). The owners sorted
          # set is not under this prefix, so it is not matched; the type check below still keeps only `list` keys.
          processing_keys << key.as(String)
        end

        break if cursor == 0
      end

      # Step 2: Batch collect jobs using pipelining for better performance
      if !processing_keys.empty?
        # Use pipelining to get queue lengths and types in batch
        queue_info = redis.pipelined do |pipe|
          processing_keys.each do |key|
            pipe.type(key)
            pipe.llen(key)
          end
        end

        # Process results and collect jobs efficiently
        processing_keys.each_with_index do |key_string, index|
          break if jobs_collected.size >= limit

          key_type = queue_info[index * 2].as(String)
          queue_length = queue_info[index * 2 + 1].as(Int64).to_i

          next unless key_type == "list"

          # Skip this queue if we haven't reached the target offset yet
          if current_offset + queue_length <= target_offset
            current_offset += queue_length
            next
          end

          # Calculate how many jobs to skip from this queue
          queue_skip = [target_offset - current_offset, 0].max
          remaining_needed = limit - jobs_collected.size
          queue_take = [queue_length - queue_skip, remaining_needed].min

          if queue_take > 0
            # Get jobs from this queue with proper offset and limit
            queue_jobs = redis.lrange(key_string, queue_skip, queue_skip + queue_take - 1)
            jobs_collected.concat(queue_jobs.map &.as(String))
          end

          current_offset += queue_length
        end
      end

      jobs_collected
    end

    # Verify that a job has been properly removed from processing queue
    def verify_job_removed_from_processing?(job_id : String, queue_name : String) : Bool
      # Across every processing list of the queue (this and other processes, and the legacy shared list)
      processing_lists(queue_name).all? do |list_key|
        redis.lrange(list_key, 0, -1).none? do |job_data|
          begin
            JSON.parse(job_data.as(String))["jid"]?.try(&.as_s) == job_id
          rescue
            false
          end
        end
      end
    rescue ex
      Log.warn &.emit("Error verifying job removal from processing queue",
        job_id: job_id, queue: queue_name, error: ex.message)
      false
    end

    # Get count of jobs currently in processing queue
    # The jobs in processing across every owner of the queue, plus the legacy shared list.
    def processing_queue_size(queue_name : String) : Int64
      processing_lists(queue_name).sum(0_i64) { |list_key| redis.llen(list_key) }
    rescue ex
      Log.warn &.emit("Error getting processing queue size",
        queue: queue_name, error: ex.message)
      0i64
    end

    # Remove job from processing queue by job ID (more reliable than JSON match)
    private def remove_job_from_processing_by_id(job_id : String, queue_name : String) : Bool
      # A process only retries or dead-letters jobs it claimed, so the job is in this process's own list (or the
      # legacy shared list, for a seeded or pre-0.6 job). Other owners' lists are not scanned: that would be a
      # cluster-wide read on a hot failure path.
      [processing_queue(queue_name), legacy_processing_queue(queue_name)].each do |list_key|
        redis.lrange(list_key, 0, -1).each do |job_json|
          begin
            if JSON.parse(job_json.to_s)["jid"]?.to_s == job_id
              redis.lrem(list_key, 0, job_json.to_s)
              return true
            end
          rescue
            next
          end
        end
      end

      false
    end

    def paused?(queue_name : String) : Bool
      redis.exists(pause_key(queue_name)) == 1
    end

    def set_paused(queue_name : String, paused : Bool) : Nil
      paused ? redis.set(pause_key(queue_name), "1") : redis.del(pause_key(queue_name))
    end

    # Compare-and-set for a reviewed operator change. A concurrent operator's
    # state is not overwritten after the preview was taken.
    def set_paused_reviewed(queue_name : String, expected : Bool, paused : Bool) : Bool
      script = <<-LUA
        if redis.call('EXISTS', KEYS[1]) ~= tonumber(ARGV[1]) then return 0 end
        if ARGV[2] == '1' then redis.call('SET', KEYS[1], '1') else redis.call('DEL', KEYS[1]) end
        return 1
      LUA
      redis.eval(script, [pause_key(queue_name)], [expected ? "1" : "0", paused ? "1" : "0"]) == 1
    end

    def desired_concurrency(queue_name : String) : {count: Int32, set_at: Int64}?
      count, set_at = redis.hmget(config_key(queue_name), "concurrency", "set_at")
      return unless count && set_at

      {count: count.to_s.to_i, set_at: set_at.to_s.to_i64}
    end

    def set_concurrency(queue_name : String, count : Int32) : Nil
      redis.hmset(config_key(queue_name), {"concurrency" => count.to_s, "set_at" => Time.utc.to_unix_ms.to_s})
    end

    private def config_key(queue_name : String) : String
      "joobq:queue:#{queue_name}:config"
    end

    private def pause_key(queue_name : String) : String
      "joobq:queue:#{queue_name}:paused"
    end

    # High-performance move to dead letter queue using pipelined operations
    def move_to_dead_letter(job : Job, queue_name : String) : Nil
      current_timestamp = Time.local.to_unix_ms
      job_json = job.to_json
      retry_lock_key = "joobq:retry_lock:#{job.jid}"

      # Persist the destination before acknowledging the source. If either write fails,
      # retain a recoverable copy; duplicates still require a fenced settlement protocol.
      DeadLetterQueue.add(redis, current_timestamp, [job_json])
      remove_job_from_processing_by_id(job.jid.to_s, queue_name)

      redis.pipelined do |pipe|
        # Clean up retry lock if it exists
        pipe.del(retry_lock_key)

        # Update statistics
        pipe.hincrby("joobq:stats:dead_letter", queue_name, 1)
        pipe.hincrby("joobq:stats:total_dead_letter", "global", 1)
      end

      Events.emit("job.dead") { {jid: job.jid.to_s, queue: queue_name} }
      Log.debug &.emit("Job moved to dead letter queue",
        job_id: job.jid.to_s,
        queue: queue_name
      )
    rescue ex
      Log.error &.emit("Failed to move job to dead letter queue",
        job_id: job.jid.to_s,
        queue: queue_name,
        error: ex.message
      )
      raise ex
    end

    # High-performance move to retry queue using pipelined operations
    def move_to_retry(job : Job, queue_name : String, delay_ms : Int64) : Bool
      schedule_time = Time.local.to_unix_ms + delay_ms
      job_json = job.to_json

      # Store the retry first, then take the job off the processing list: a failure in between leaves the job
      # in processing (to be reclaimed or dead-lettered), never in neither place.
      redis.pipelined do |pipe|
        # Add to delayed queue with future timestamp
        pipe.zadd(DELAYED_SET, schedule_time, job_json)

        # Update statistics
        pipe.hincrby("joobq:stats:retries", queue_name, 1)
        pipe.hincrby("joobq:stats:total_retries", "global", 1)
      end

      # Remove job by ID from processing queue (more reliable than JSON match)
      remove_job_from_processing_by_id(job.jid.to_s, queue_name)

      Events.emit("job.retrying") { {jid: job.jid.to_s, queue: queue_name, delay_ms: delay_ms} }
      Log.debug &.emit("Job moved to retry queue",
        job_id: job.jid.to_s,
        queue: queue_name,
        delay_ms: delay_ms,
        schedule_time: schedule_time
      )

      true
    rescue ex
      Log.error &.emit("Failed to move job to retry queue",
        job_id: job.jid.to_s,
        queue: queue_name,
        error: ex.message
      )
      false
    end

    # Schedule delayed retry - simplified version of move_to_retry
    def schedule_delayed_retry(job : Job, queue_name : String, delay_ms : Int64) : Bool
      move_to_retry(job, queue_name, delay_ms)
    end

    # Claims the oldest job (see `dequeue`)
    def claim_job(queue_name : String, worker_id : String, klass : Class) : String?
      dequeue(queue_name, klass)
    end

    # Claims up to `batch_size` jobs, oldest first (see `dequeue_batch`)
    def claim_jobs_batch(queue_name : String, worker_id : String, klass : Class, batch_size : Int32 = 5) : Array(String)
      dequeue_batch(queue_name, klass, batch_size)
    end

    # Nothing to release: a claim is the job's place in the processing list, which completion, retry or
    # dead-lettering removes
    def release_job_claim(queue_name : String, worker_id : String) : Nil
    end

    # Nothing to release (see `release_job_claim`)
    def release_job_claims_batch(queue_name : String, worker_id : String, job_count : Int32) : Nil
    end

    # Source membership is the claim: competing schedulers cannot promote the same
    # member twice. Write the destination first: Lua does not roll back on errors.
    # JSON is parsed/re-encoded in Crystal, preserving Int64 values (Lua cjson uses doubles).
    PROMOTE_DUE = <<-LUA
      local score = redis.call('ZSCORE', KEYS[1], ARGV[1])
      if not score or tonumber(score) > tonumber(ARGV[3]) then return 0 end
      redis.call('RPUSH', KEYS[2], ARGV[2])
      redis.call('ZREM', KEYS[1], ARGV[1])
      return 1
    LUA

    def promote_due_jobs(current_time : Time = Time.utc, delay_set : String = DELAYED_SET,
                         queue_name : String? = nil, limit : Int32 = 50, *, report_scanned : Bool = false) : Array(String)
      scanned = fetch_due_jobs(current_time, delay_set, limit, remove: false)
      moved = Array(String).new(scanned.size)
      now = current_time.to_unix_ms.to_s
      scanned.each do |raw|
        begin
          next if queue_name && SerializedJob.queue_name(raw) != queue_name
          destination, payload = SerializedJob.for_enqueue(raw)
          if promote_due([delay_set, destination], [raw, payload, now]) == 1
            moved << raw
          end
        rescue ex
          # Malformed and unavailable destinations remain inspectable and retryable.
          Log.error &.emit("Delayed job promotion was not confirmed; inspect source and destination", delay_set: delay_set, error: ex.message)
        end
      end
      report_scanned ? scanned : moved
    end

    private PROMOTE_DUE_SHA = Digest::SHA1.hexdigest(PROMOTE_DUE)

    private def promote_due(keys : Array(String), args : Array(String))
      redis.evalsha(PROMOTE_DUE_SHA, keys, args)
    rescue ex : Redis::Error
      # A definite cache miss is safe to retry. Timeouts/ambiguous writes are not.
      raise ex unless ex.message.try(&.starts_with?("NOSCRIPT"))
      redis.eval(PROMOTE_DUE, keys, args)
    end

    # Preserve the legacy return contract: all scanned due jobs, including other queues.
    def process_due_delayed_jobs(queue_name : String) : Array(String)
      promote_due_jobs(queue_name: queue_name, report_scanned: true)
    end

    # Verify that a job exists in only one location (for debugging/testing)
    # Returns a hash with the job's locations
    def verify_job_uniqueness(job_jid : String, queue_name : String) : Hash(String, Int32)
      locations = {
        "main_queue"  => 0,
        "processing"  => 0,
        "delayed"     => 0,
        "dead_letter" => 0,
      }

      # Check main queue
      main_jobs = redis.lrange(queue_name, 0, -1)
      locations["main_queue"] = main_jobs.count { |j| j.as(String).includes?(job_jid) }

      # Check processing (every owner of the queue, plus the legacy shared list)
      locations["processing"] = processing_lists(queue_name).sum(0) do |list_key|
        redis.lrange(list_key, 0, -1).count { |j| j.as(String).includes?(job_jid) }
      end

      # Check delayed queue
      delayed_jobs = redis.zrange(DELAYED_SET, 0, -1)
      locations["delayed"] = delayed_jobs.count { |j| j.as(String).includes?(job_jid) }

      # Check dead letter queue
      dead_jobs = redis.zrange(DEAD_LETTER, 0, -1)
      locations["dead_letter"] = dead_jobs.count { |j| j.as(String).includes?(job_jid) }

      total_locations = locations.values.sum

      if total_locations > 1
        Log.warn &.emit("Job exists in multiple locations",
          job_id: job_jid,
          queue: queue_name,
          locations: locations.to_s
        )
      elsif total_locations == 0
        Log.debug &.emit("Job not found in any location",
          job_id: job_jid,
          queue: queue_name
        )
      end

      locations
    rescue ex
      Log.error &.emit("Error verifying job uniqueness",
        job_id: job_jid,
        queue: queue_name,
        error: ex.message
      )
      locations
    end

    # This process's own processing list for a queue: where it claims into and cleans up from.
    private def processing_queue(name : String)
      "#{PROCESSING_QUEUE}:#{name}:#{@owner_id}"
    end

    # The shared list older (0.5) workers claimed into, and the one many specs seed directly. 0.6 claims never land
    # here, but cleanup and recovery still handle it so a mixed cluster and an upgrade lose nothing.
    private def legacy_processing_queue(name : String)
      "#{PROCESSING_QUEUE}:#{name}"
    end

    # Optimized method to get processing jobs count using Lua script
    def get_processing_jobs_count : Int32
      @metrics.get_processing_jobs_count
    end

    # Optimized retrying jobs count using Lua script for better performance
    def get_retrying_jobs_count : Int32
      @metrics.get_retrying_jobs_count
    end

    # Optimized retrying jobs pagination using Lua script
    def get_retrying_jobs_paginated(page : Int32, per_page : Int32) : Array(String)
      @metrics.get_retrying_jobs_paginated(page, per_page)
    end

    # Simplified batch job lookup - search in all known locations
    def find_jobs_batch(jids : Array(String)) : Hash(String, String?)
      results = {} of String => String?
      jids.each { |jid| results[jid] = nil }

      # Search in main locations: delayed set, dead letter, and main queues
      locations = [DELAYED_SET, DEAD_LETTER]
      JoobQ.queues.each do |queue_name, _|
        locations << queue_name
      end

      locations.each do |location|
        key_type = redis.type(location)

        jobs = case key_type
               when "list"
                 redis.lrange(location, 0, -1)
               when "zset"
                 redis.zrange(location, 0, -1)
               else
                 [] of Redis::RedisValue
               end

        jobs.each do |job_json|
          job_str = job_json.as(String)
          jids.each do |jid|
            if job_str.includes?(jid) && results[jid].nil?
              results[jid] = job_str
            end
          end
        end
      end

      results
    rescue ex
      Log.warn &.emit("Error in batch job lookup", error: ex.message)
      results
    end

    # Optimized method to get job counts for multiple states at once
    def get_multiple_state_counts(states : Array(String)) : Hash(String, Int32)
      @metrics.get_multiple_state_counts(states)
    end
  end
end
