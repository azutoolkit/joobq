module JoobQ
  # BaseQueue remains as the abstract base class
  module BaseQueue
    # Override for explicitly injected execution dependencies; serialized jobs do
    # not carry process-local store handles.
    def perform(job : Job) : Nil
      job.perform
    end

    abstract def add(job : String)
    abstract def add!(job : String) : String
    abstract def add_delayed(job : String, at : Time) : String
    abstract def start
    abstract def stop!
    abstract def pause!
    abstract def resume!
    abstract def paused? : Bool
    abstract def resize(count : Int32)
    abstract def apply_concurrency(count : Int32)
    abstract def name : String
    abstract def size : Int64
    abstract def job_type : String
    abstract def total_workers : Int32
    abstract def running_workers : Int32
    abstract def status : String
    abstract def throttle_limit : NamedTuple(limit: Int32, period: Time::Span)?
  end

  # The Queue class now focuses solely on queue operations
  class Queue(T)
    include BaseQueue
    getter store : Store
    getter name : String
    getter job_type : String = T.name
    getter total_workers : Int32
    getter worker_manager : WorkerManager(T) { WorkerManager(T).new(total_workers, self) }
    getter throttle_limit : NamedTuple(limit: Int32, period: Time::Span)?

    PAUSE_CACHE_TTL = 500.milliseconds

    @started = Atomic(Bool).new(false)

    def initialize(@name : String, @total_workers : Int32,
                   @throttle_limit : NamedTuple(limit: Int32, period: Time::Span)? = nil,
                   *, @store : Store = ::JoobQ.config.store, @handler : Proc(T, Nil)? = nil)
      @pause = CachedFlag.new(PAUSE_CACHE_TTL) { store.paused?(name) }
    end

    def perform(job : Job) : Nil
      if job.is_a?(T)
        if handler = @handler
          handler.call(job)
        else
          job.perform
        end
      else
        raise ArgumentError.new("Job type does not belong to queue #{name}")
      end
    end

    # Starting a running queue does nothing: `reprocess_busy_jobs!` would move a job that a worker is
    # still processing back onto the queue, and it would run twice.
    def start
      verify_encryption_keys
      return if @started.swap(true)

      reprocess_busy_jobs!
      worker_manager.start_workers
    end

    # A queue of a job class with encrypted properties does not start without valid keys: better to fail at start-up
    # than to find out at the first job.
    private def verify_encryption_keys : Nil
      {% for type in T.union_types %}
        {% for iv in type.instance_vars %}
          {% ann = iv.annotation(JSON::Field) %}
          {% if ann && ann[:converter] && ann[:converter].stringify.includes?("Encryption::Field") %}
            Encryption.keys
          {% end %}
        {% end %}
      {% end %}
    end

    def parse_job(job : String) : T
      T.from_json(job)
    end

    def add(job : String)
      add T.from_json(job)
    rescue ex : Encryption::Error
      raise ex # a key problem must reach the caller, not just the log
    rescue ex
      handle_enqueue_error(ex, job, "string_job")
    end

    # Strict variant of `add`: a payload that does not deserialize into this queue's job type raises
    # (`JSON::ParseException`, `JSON::SerializableError`) instead of being logged, and the job id comes back.
    # Store and connection errors raise as well. The job always lands on this queue: a `queue` in the payload is
    # overridden, because the store pushes onto `job.queue`, which would otherwise let a payload pick any Redis key.
    # `add`, `add_batch` and `add_batch_strings` still trust the `queue` in the payload, so do not feed them untrusted input.
    def add!(job : String) : String
      job_object = T.from_json(job)
      job_object.queue = name
      store.enqueue job_object
    end

    # Schedules a serialized job to move onto the queue at `at`, and returns its job id. Raises like `add!` when the
    # payload does not fit this queue's job type, and, like `add!`, ignores a `queue` in the payload. The delayed-job
    # scheduler moves it when it is due.
    def add_delayed(job : String, at : Time) : String
      job_object = T.from_json(job)
      job_object.queue = name
      job_object.scheduled!
      store.schedule_job(job_object.to_json, at.to_unix_ms)
      job_object.jid.to_s
    end

    def add(job : T)
      store.enqueue job
    rescue ex : Encryption::Error
      raise ex
    rescue ex
      handle_enqueue_error(ex, job.to_json, "typed_job")
    end

    # Batch add jobs with pipelining for improved performance
    def add_batch(jobs : Array(T))
      add_batch_pipelined(jobs)
    rescue ex : Encryption::Error
      raise ex
    rescue ex
      Log.error &.emit("Error adding job batch", queue: name, job_count: jobs.size, error: ex.message)
    end

    # Add batch of job strings
    def add_batch_strings(jobs : Array(String))
      add_batch_strings_pipelined(jobs)
    rescue ex : Encryption::Error
      raise ex
    rescue ex
      Log.error &.emit("Error adding job batch strings", queue: name, job_count: jobs.size, error: ex.message)
    end

    private def add_batch_pipelined(jobs : Array(T))
      store.enqueue_batch(jobs, JoobQ.config.pipeline_batch_size)
    end

    private def add_batch_strings_pipelined(jobs : Array(String))
      # Convert strings to Job objects for batch enqueuing
      # A string that cannot be loaded here (a sealed value this process cannot open, say) is not dropped, and does not
      # take the rest of the batch with it: it goes onto the queue as it is, for a worker to deal with.
      job_objects = [] of T
      unreadable = [] of String
      jobs.each do |job_str|
        job_objects << T.from_json(job_str)
      rescue ex : JSON::Error
        Log.warn &.emit("Job kept as stored; it could not be loaded here", queue: name, error: ex.message)
        unreadable << job_str
      end
      # After the rest is stored, and in one transaction: if enqueue_batch raises, nothing was written for the
      # unreadable ones, so a caller that retries the whole batch cannot duplicate them.
      store.enqueue_batch(job_objects, JoobQ.config.pipeline_batch_size)
      if !unreadable.empty? && (redis_store = store).is_a?(RedisStore)
        redis_store.redis.multi { |multi| unreadable.each { |job_str| multi.rpush(name, job_str) } }
      end
    end

    private def handle_enqueue_error(ex : Exception, job_data : String, job_type : String)
      error_context = {
        queue:           name,
        job_type:        job_type,
        error_class:     ex.class.name,
        error_message:   ex.message || "Unknown error",
        job_data_length: job_data.size.to_s,
        queue_size:      size.to_s,
        queue_workers:   total_workers.to_s,
        occurred_at:     Time.local.to_rfc3339,
      }

      Log.error &.emit("Failed to enqueue job", error_context)

      # For critical enqueue failures, we might want to raise or handle differently
      case ex
      when Redis::CannotConnectError
        Log.error &.emit("Redis connection failed during enqueue", error_context)
        raise ex # Re-raise connection errors as they're critical
      when JSON::Error
        Log.error &.emit("Invalid job data format", error_context)
        # Don't re-raise JSON errors, just log them
      else
        Log.error &.emit("Unexpected error during enqueue", error_context)
      end
    end

    def delete_job(job : String)
      store.delete_job job
    end

    def mark_as_dead(job : String)
      expires = JoobQ.config.dead_letter_ttl.total_seconds.to_i
      job_obj = T.from_json(job)
      store.mark_as_dead job_obj, expires
    end

    def retry(job : String)
      job_data = JSON.parse(job)
      retries = job_data["retries"]?.try(&.as_i) || 0
      delay_ms = (2 ** retries) * 1000_i64             # Delay in ms
      schedule_time = Time.local.to_unix_ms + delay_ms # Calculate when job should run

      # Use store to schedule the job string
      store.schedule_job(job, schedule_time)
    end

    def size : Int64
      store.queue_size name
    end

    def running? : Bool
      worker_manager.running?
    end

    def running_workers : Int32
      worker_manager.running_workers
    end

    def clear
      store.clear_queue name
    end

    def jobs(page_number : Int32 = 1, page_size : Int32 = 200)
      store.list_jobs(name)
    end

    def stop!
      worker_manager.stop_workers
      @started.set(false)
    end

    # Changes the number of workers at runtime. The new size is stored so every
    # process serving this queue follows it (see WorkerRegistry).
    def resize(count : Int32)
      raise ArgumentError.new("workers must be positive") unless count > 0

      store.set_concurrency(name, count)
      apply_concurrency(count)
      Events.emit("queue.resized") { {queue: name, concurrency: count} }
    end

    # Resizes this process only; used when following a size set elsewhere.
    def apply_concurrency(count : Int32)
      raise ArgumentError.new("workers must be positive") unless count > 0

      @total_workers = count
      worker_manager.resize(count)
    end

    # Pausing is shared through the store, so it holds across processes.
    def pause!
      store.set_paused(name, true)
      @pause.set(true)
      Events.emit("queue.paused") { {queue: name} }
    end

    def resume!
      store.set_paused(name, false)
      @pause.set(false)
      Events.emit("queue.resumed") { {queue: name} }
    end

    def paused? : Bool
      @pause.get
    end

    def next_job : String?
      store.dequeue(name, T)
    rescue ex
      Log.error &.emit("Error Dequeuing", queue: name, error: ex.message)
      nil
    end

    def claim_job(worker_id : String) : String?
      store.claim_job(name, worker_id, T)
    rescue ex
      Log.error &.emit("Error Claiming Job", queue: name, worker: worker_id, error: ex.message)
      nil
    end

    def claim_jobs_batch(worker_id : String, batch_size : Int32 = 5) : Array(String)
      store.claim_jobs_batch(name, worker_id, T, batch_size)
    rescue ex
      Log.error &.emit("Error Claiming Jobs Batch", queue: name, worker: worker_id,
        batch_size: batch_size, error: ex.message)
      [] of String
    end

    def release_job_claim(worker_id : String) : Nil
      store.release_job_claim(name, worker_id)
    rescue ex
      Log.error &.emit("Error Releasing Job Claim", queue: name, worker: worker_id, error: ex.message)
    end

    def release_job_claims_batch(worker_id : String, job_count : Int32) : Nil
      store.release_job_claims_batch(name, worker_id, job_count)
    rescue ex
      Log.error &.emit("Error Releasing Job Claims Batch", queue: name, worker: worker_id,
        job_count: job_count, error: ex.message)
    end

    # Pipelined job cleanup for improved performance
    # IMPORTANT: job_json must be the FULL job JSON string, not just the job ID
    def cleanup_job_processing_pipelined(worker_id : String, job_json : String) : Nil
      store.cleanup_job(job_json, name)
    rescue ex
      Log.error &.emit("Error in pipelined job cleanup", queue: name, worker: worker_id,
        job_data_length: job_json.size, error: ex.message)
    end

    # Enhanced cleanup for successfully completed jobs
    # IMPORTANT: job_json must be the FULL job JSON string, not just the job ID
    def cleanup_completed_job_pipelined(worker_id : String, job_json : String) : Nil
      store.mark_job_completed(job_json, name)
    rescue ex
      Log.error &.emit("Error in completed job cleanup", queue: name, worker: worker_id,
        job_data_length: job_json.size, error: ex.message)
    end

    # Verify that a job has been properly removed from processing queue
    def verify_job_removed_from_processing?(job_id : String) : Bool
      store.verify_job_removed_from_processing?(job_id, name)
    end

    # Get count of jobs currently in processing queue
    def processing_queue_size : Int64
      store.processing_queue_size(name)
    end

    # Batch job cleanup for improved performance
    def cleanup_jobs_batch_pipelined(worker_id : String, job_ids : Array(String)) : Nil
      # Note: This method expects job JSON strings, not just job IDs
      # For now, we'll need to find the actual job JSON strings
      store.cleanup_jobs_batch(job_ids, name)
    rescue ex
      Log.error &.emit("Error in batch job cleanup", queue: name, worker: worker_id,
        job_count: job_ids.size, error: ex.message)
    end

    def status : String
      if size.zero? && running?
        return "Awaiting"
      end
      running? ? "Running" : "Done"
    end

    private def reprocess_busy_jobs!
      store.move_job_back_to_queue(name)
    end
  end
end
