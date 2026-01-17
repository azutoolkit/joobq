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
        ExponentialBackoff.cleanup_retry_lock(job, queue)
        # Note: Job removal from processing is handled by the worker cleanup process

      rescue ex : Exception
        handle_failure(job, queue, ex, worker_id)
      end

      private def handle_failure(job : JoobQ::Job, queue : BaseQueue, ex : Exception, worker_id : String)
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
          }
        )

        # Simple logic: if retries > 0, then retry, otherwise move to dead letter queue
        if current_retries > 0
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
          else
            Log.warn &.emit("Job retry already in progress, skipping duplicate retry",
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

    # Idempotent retry that prevents duplicate retries for the same job
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

      # Use Redis SET with NX (only if not exists) and EX (expiration) for atomic lock
      lock_acquired = redis_store.redis.set(retry_lock_key, "retrying", nx: true, ex: lock_ttl)

      if lock_acquired == "OK"
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
        # Lock already exists, retry already in progress
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
