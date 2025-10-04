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
        ExponentialBackoff.cleanup_retry_lock_atomic(job, queue)
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

          # Use idempotent retry with atomic operations to prevent duplicate retries
          # Pass the actual retry attempt number for exponential backoff calculation
          # Note: Removal is done by job ID in Lua script, not JSON matching
          success, updated_job = ExponentialBackoff.retry_idempotent_atomic(
            job, queue, retry_attempt
          )
          if success
            Log.info &.emit("Job retry scheduled successfully (atomic)",
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
          # No more retries left, send to dead letter queue atomically
          move_to_dead_letter_atomic(job, queue, error_context)
        end
      end

      private def move_to_dead_letter_atomic(job : JoobQ::Job, queue : BaseQueue, error_context)
        # Atomically move job from processing to dead letter queue
        # This single operation removes from processing (by job ID), adds to dead letter, and cleans up retry lock
        # Note: Removal is done by job ID in Lua script, not JSON matching
        updated_job = ExponentialBackoff.move_to_dead_letter_atomic(job, queue)

        Log.info &.emit("Job moved to dead letter queue atomically with error information",
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
    # Retry lock expiration time (30 seconds - enough for scheduling, not excessive)
    private RETRY_LOCK_TTL = 30

    # Atomic idempotent retry that prevents duplicate retries for the same job
    # Uses Lua script to remove by job ID (not JSON matching)
    # Returns a tuple of (success: Bool, modified_job: Job)
    def self.retry_idempotent_atomic(job : JoobQ::Job, queue : BaseQueue, retry_attempt : Int32) : {Bool, JoobQ::Job}
      return {false, job} unless queue.store.is_a?(RedisStore)

      retry_lock_key = "#{RETRY_LOCK_PREFIX}:#{job.jid}"
      redis_store = queue.store.as(RedisStore)

      # Use Redis SET with NX (only if not exists) and EX (expiration) for atomic lock
      lock_acquired = redis_store.redis.set(retry_lock_key, "retrying", nx: true, ex: RETRY_LOCK_TTL)

      if lock_acquired == "OK"
        begin
          # Calculate exponential backoff delay: 2^retry_attempt * 1000ms
          # Cap the delay at 1 hour to prevent extremely long delays
          # Ensure retry_attempt is never negative
          safe_retry_attempt = Math.max(0, retry_attempt)
          delay_ms = [(2.0 ** safe_retry_attempt).to_i * 1000, 3_600_000].min

          # Mark job as retrying
          job.retrying!

          # Atomically move job from processing to retry queue
          # Removal is done by job ID (in Lua script), not JSON matching
          # This ensures the job is removed from processing and scheduled in a single atomic operation
          success = redis_store.move_to_retry_atomic(job, queue.name, delay_ms.to_i64)

          if success
            Log.info &.emit("Job scheduled for idempotent retry with exponential backoff (atomic)",
              job_id: job.jid.to_s,
              queue: queue.name,
              retry_attempt: retry_attempt,
              delay_ms: delay_ms,
              remaining_retries: job.retries
            )
            return {true, job}
          else
            # If move failed, remove the lock to allow future retries
            redis_store.redis.del(retry_lock_key)
            return {false, job}
          end
        rescue ex : Exception
          # If scheduling fails, remove the lock to allow future retries
          redis_store.redis.del(retry_lock_key)
          Log.error &.emit("Failed to schedule retry atomically, removed lock",
            job_id: job.jid.to_s,
            queue: queue.name,
            error: ex.message
          )
          raise ex
        end
      else
        # Lock already exists, retry already in progress
        return {false, job}
      end
    end

    # Atomically move job from processing to dead letter queue
    # Uses Lua script to remove by job ID (not JSON matching)
    # Returns the modified job with dead status
    def self.move_to_dead_letter_atomic(job : JoobQ::Job, queue : BaseQueue) : JoobQ::Job
      return job unless queue.store.is_a?(RedisStore)

      # Set job status to Dead before moving to dead letter queue
      job.dead!

      redis_store = queue.store.as(RedisStore)

      # Use the atomic operation from RedisStore (removes by job ID)
      redis_store.move_to_dead_letter_atomic(job, queue.name)

      Log.debug &.emit("Job moved to dead letter queue atomically",
        job_id: job.jid.to_s,
        queue: queue.name
      )

      job
    rescue ex : Exception
      Log.error &.emit("Failed to move job to dead letter queue atomically",
        job_id: job.jid.to_s,
        queue: queue.name,
        error: ex.message
      )
      raise ex
    end

    # Clean up retry lock and job lock when job completes successfully
    def self.cleanup_retry_lock_atomic(job : JoobQ::Job, queue : BaseQueue) : Nil
      return unless queue.store.is_a?(RedisStore)

      redis_store = queue.store.as(RedisStore)
      job_lock_key = "joobq:job_lock:#{job.jid}"
      retry_lock_key = "joobq:retry_lock:#{job.jid}"

      # Clean up both locks
      redis_store.redis.pipelined do |pipe|
        pipe.del(retry_lock_key)
        pipe.del(job_lock_key)
      end

      Log.debug &.emit("Retry lock and job lock cleaned up for job",
        job_id: job.jid.to_s,
        queue: queue.name
      )
    rescue ex : Exception
      Log.error &.emit("Failed to cleanup locks",
        job_id: job.jid.to_s,
        queue: queue.name,
        error: ex.message
      )
    end
  end
end
