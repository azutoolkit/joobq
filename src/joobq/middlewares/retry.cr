module JoobQ
  module Middleware
    class Retry
      include Middleware

      def matches?(job : JoobQ::Job, queue : BaseQueue) : Bool
        true # This middleware applies to all jobs
      end

      def call(job : JoobQ::Job, queue : BaseQueue, worker_id : String, next_middleware : ->) : Nil
        next_middleware.call
        # Job completed successfully, clean up any retry lock
        ExponentialBackoff.cleanup_retry_lock(job, queue) unless InFlight.abandoned?
        # Note: Job removal from processing is handled by the worker cleanup process

      rescue ex : Exception
        handle_failure(job, queue, ex, worker_id)
      end

      private def handle_failure(job : JoobQ::Job, queue : BaseQueue, ex : Exception, worker_id : String)
        # Shutdown gave up on this execution and put the job back on its queue: retrying or dead-lettering it here
        # would schedule it a second time
        unless InFlight.settle # also marks the job as settling, so shutdown does not requeue it meanwhile
          Log.info &.emit("Failure of an execution abandoned at shutdown; the requeued job is not touched",
            job_id: job.jid.to_s, queue: queue.name, error: ex.message)
          return
        end

        # Get current remaining retries
        current_retries = job.retries

        # Get the original max retries for this job
        max_retries = job.max_retries

        # Calculate the actual retry attempt number (0-indexed)
        # Example: max_retries=3, current_retries=3 → attempt 0 (first try, not a retry yet)
        # Example: max_retries=3, current_retries=2 → attempt 1 (first retry)
        # Example: max_retries=3, current_retries=1 → attempt 2 (second retry)
        # Example: max_retries=3, current_retries=0 → attempt 3 (third/final retry)
        retry_attempt = max_retries - current_retries

        # Use the monitored error handling system with correct retry count
        error_context = MonitoredErrorHandler.handle_job_error(
          job,
          queue,
          ex,
          worker_id: worker_id,
          retry_count: retry_attempt,
          additional_context: {
            "middleware"      => "retry",
            "max_retries"     => max_retries.to_s,
            "current_retries" => current_retries.to_s,
            "retry_attempt"   => retry_attempt.to_s,
            "worker_id"       => worker_id,
          },
          schedule: false # this middleware does the scheduling, once
        )
        # A struct job is a copy here: the error goes on this copy, the one that is stored below
        job = ErrorHandler.update_job_with_error(job, error_context)

        # Retry while the job has budget left, unless the error says retrying cannot help; then dead letter, once
        if current_retries > 0 && !ex.is_a?(NonRetryableError)
          # Decrement retries
          job.retries = current_retries - 1

          # Use idempotent retry with simple operations
          # Pass the actual retry attempt number for exponential backoff calculation
          success, updated_job = ExponentialBackoff.retry_idempotent(
            job, queue, retry_attempt
          )
          if success
            Log.info &.emit("Job retry scheduled successfully",
              job_id: updated_job.jid.to_s,
              queue: queue.name,
              retry_attempt: retry_attempt,
              retries_remaining: updated_job.retries,
              max_retries: max_retries
            )
          elsif updated_job.retrying?
            # The retry was attempted (the job was marked retrying) but could not be stored: do not lose the job.
            Log.error &.emit("Job retry could not be stored, moving the job to the dead letter queue",
              job_id: job.jid.to_s,
              queue: queue.name
            )
            move_to_dead_letter(job, queue, error_context)
          else
            Log.warn &.emit("This failure's retry is already scheduled, skipping the duplicate",
              job_id: job.jid.to_s,
              queue: queue.name
            )
          end
        else
          # No more retries left, send to dead letter queue
          move_to_dead_letter(job, queue, error_context)
        end
      end

      private def move_to_dead_letter(job : JoobQ::Job, queue : BaseQueue, error_context)
        # Move job from processing to dead letter queue
        updated_job = ExponentialBackoff.move_to_dead_letter(job, queue)

        Log.info &.emit("Job moved to dead letter queue with error information",
          job_id: updated_job.jid.to_s,
          queue: queue.name,
          error_type: error_context.error_type,
          has_backtrace: !error_context.backtrace.empty?
        )
      end
    end
  end

  class ExponentialBackoff
    # Retry lock key prefix for Redis
    private RETRY_LOCK_PREFIX = "joobq:retry_lock"
    # Base retry lock TTL - will be extended based on actual delay
    private RETRY_LOCK_BASE_TTL = 60
    # Maximum delay in milliseconds (1 hour)
    private MAX_DELAY_MS = 3_600_000_i64

    # Takes the retry lock for one failure of a job: the lock holds the attempt that failed, so a second handler
    # of that same failure finds it and backs off, while the job's next failure (another attempt) replaces it.
    # The lock is still there when the retry it guarded runs and fails again: keyed by the job alone, that
    # failure was skipped and the job lost. One key per job, so every place that clears it still does.
    ACQUIRE_RETRY_LOCK = <<-LUA
      if redis.call('GET', KEYS[1]) == ARGV[1] then return 0 end
      redis.call('SET', KEYS[1], ARGV[1], 'EX', ARGV[2])
      return 1
    LUA

    # Idempotent retry: schedules each failure of a job once, however many handlers see that failure
    # Returns a tuple of (success: Bool, modified_job: Job)
    def self.retry_idempotent(job : JoobQ::Job, queue : BaseQueue, retry_attempt : Int32) : {Bool, JoobQ::Job}
      return {false, job} unless queue.store.is_a?(RedisStore)

      retry_lock_key = "#{RETRY_LOCK_PREFIX}:#{job.jid}"
      redis_store = queue.store.as(RedisStore)

      # Calculate delay first so we can set appropriate lock TTL
      # Clamp retry_attempt to prevent overflow (max 22 gives ~4 million ms before cap)
      safe_retry_attempt = Math.min(Math.max(0, retry_attempt), 22)
      delay_ms = Math.min((2_i64 ** safe_retry_attempt) * 1000_i64, MAX_DELAY_MS)

      # Set lock TTL to be delay + buffer to prevent duplicate retries
      lock_ttl = (delay_ms / 1000).to_i + RETRY_LOCK_BASE_TTL

      lock_acquired = redis_store.redis.eval(ACQUIRE_RETRY_LOCK, [retry_lock_key], ["attempt:#{retry_attempt}", lock_ttl.to_s]) == 1

      if lock_acquired
        move_succeeded = false
        begin
          # Mark job as retrying
          job.retrying!

          # Move job from processing to retry queue using simplified method
          move_succeeded = redis_store.move_to_retry(job, queue.name, delay_ms.to_i64)

          if move_succeeded
            Log.info &.emit("Job scheduled for idempotent retry with exponential backoff",
              job_id: job.jid.to_s,
              queue: queue.name,
              retry_attempt: retry_attempt,
              delay_ms: delay_ms,
              remaining_retries: job.retries
            )
            return {true, job}
          else
            Log.warn &.emit("Failed to move job to retry queue",
              job_id: job.jid.to_s,
              queue: queue.name)
            return {false, job}
          end
        rescue ex : Exception
          Log.error &.emit("Exception during retry scheduling",
            job_id: job.jid.to_s,
            queue: queue.name,
            error: ex.message
          )
          return {false, job}
        ensure
          # Always clean up lock if move didn't succeed to allow future retries
          unless move_succeeded
            redis_store.redis.del(retry_lock_key) rescue nil
          end
        end
      else
        # This failure (this attempt) has already been scheduled
        return {false, job}
      end
    end

    # Move job from processing to dead letter queue
    # Returns the modified job with dead status
    def self.move_to_dead_letter(job : JoobQ::Job, queue : BaseQueue) : JoobQ::Job
      return job unless queue.store.is_a?(RedisStore)

      # Set job status to Dead before moving to dead letter queue
      job.dead!

      redis_store = queue.store.as(RedisStore)

      # Use the simplified operation from RedisStore
      redis_store.move_to_dead_letter(job, queue.name)

      Log.debug &.emit("Job moved to dead letter queue",
        job_id: job.jid.to_s,
        queue: queue.name
      )

      job
    rescue ex : Exception
      Log.error &.emit("Failed to move job to dead letter queue",
        job_id: job.jid.to_s,
        queue: queue.name,
        error: ex.message
      )
      raise ex
    end

    # Clean up retry lock when job completes successfully
    def self.cleanup_retry_lock(job : JoobQ::Job, queue : BaseQueue) : Nil
      return unless queue.store.is_a?(RedisStore)

      redis_store = queue.store.as(RedisStore)
      retry_lock_key = "joobq:retry_lock:#{job.jid}"

      # Clean up retry lock only (no job locks in BRPOPLPUSH pattern)
      redis_store.redis.del(retry_lock_key)

      Log.debug &.emit("Retry lock cleaned up for job",
        job_id: job.jid.to_s,
        queue: queue.name
      )
    rescue ex : Exception
      Log.error &.emit("Failed to cleanup retry lock",
        job_id: job.jid.to_s,
        queue: queue.name,
        error: ex.message
      )
    end
  end
end
