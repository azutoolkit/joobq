module JoobQ
  class ExpiredJobReaper
    Log = ::Log.for("EXPIRED_JOB_REAPER")

    PAGE_SIZE   = 100
    DEAD_LETTER = "joobq:dead_letter"

    @loop = BackgroundLoop.new("expired_job_reaper")

    def initialize(
      @store : Store = RedisStore.instance,
      @interval : Time::Span = 30.seconds,
      @scan_limit : Int32 = 1000,
    )
    end

    def start
      started = @loop.start do
        reap_expired_jobs
        @interval
      end
      return unless started

      Log.info &.emit("Expired job reaper started",
        interval_seconds: @interval.total_seconds,
        scan_limit: @scan_limit
      )
    end

    def stop
      return unless @loop.stop
      Log.info &.emit("Expired job reaper stopped")
    end

    # Public method for testability — runs a single reap cycle
    def reap_once
      reap_expired_jobs
    end

    private def reap_expired_jobs
      return unless @store.is_a?(RedisStore)

      redis_store = @store.as(RedisStore)

      JoobQ.queues.each do |queue_name, _|
        begin
          # Return crashed/stopped processes' in-flight jobs to the head of the queue (never a live process's); any
          # expired ones are then reaped by the waiting scan below.
          recovered = redis_store.recover_orphaned_processing(queue_name)

          reaped_waiting = scan_and_reap_queue(redis_store, queue_name)

          # Reap expired jobs only from the legacy shared list. A live process's own list is left to that process
          # (its Timeout middleware), so the reaper never dead-letters a job a worker is still running; a crashed
          # process's list is emptied by recovery above before this runs.
          reaped_processing = scan_and_reap_queue(redis_store, "joobq:processing:#{queue_name}", stats_queue: queue_name)

          total = reaped_waiting + reaped_processing
          if total > 0 || recovered > 0
            Log.info &.emit("Reaped expired jobs",
              queue: queue_name,
              from_waiting: reaped_waiting,
              from_processing: reaped_processing,
              recovered: recovered
            )
          end
        rescue ex
          Log.error &.emit("Error reaping expired jobs for queue",
            queue: queue_name,
            error: ex.message
          )
        end
      end
    end

    private def scan_and_reap_queue(
      redis_store : RedisStore,
      list_key : String,
      stats_queue : String? = nil,
    ) : Int32
      stats_key = stats_queue || list_key
      current_time_ms = Time.local.to_unix_ms
      total_reaped = 0
      total_scanned = 0
      offset = 0

      loop do
        break if total_scanned >= @scan_limit

        batch_size = Math.min(PAGE_SIZE, @scan_limit - total_scanned)
        jobs = redis_store.redis.lrange(list_key, offset, offset + batch_size - 1).map(&.as(String))
        break if jobs.empty?

        total_scanned += jobs.size
        expired_jobs = [] of String

        jobs.each do |job_json|
          begin
            parsed = JSON.parse(job_json)
            expires = parsed["expires"]?.try(&.as_i64)
            next unless expires
            expired_jobs << job_json if current_time_ms > expires
          rescue ex
            Log.warn &.emit("Failed to parse job during reaping",
              list_key: list_key,
              error: ex.message
            )
          end
        end

        if !expired_jobs.empty?
          # Dead first: a crash between the two leaves a copy in both places rather than none.
          DeadLetterQueue.add(redis_store.redis, current_time_ms, expired_jobs)
          redis_store.redis.pipelined do |pipe|
            expired_jobs.each { |job_json| pipe.lrem(list_key, 0, job_json) }
            pipe.hincrby("joobq:stats:expired", stats_key, expired_jobs.size)
            pipe.hincrby("joobq:stats:dead_letter", stats_key, expired_jobs.size)
          end
          total_reaped += expired_jobs.size
          # Removed items shift list down; advance past non-expired items only
          offset += (jobs.size - expired_jobs.size)
        else
          offset += jobs.size
        end

        break if jobs.size < batch_size
      end

      total_reaped
    end
  end
end
