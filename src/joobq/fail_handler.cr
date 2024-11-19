module JoobQ
  # The `FailHandler` module in JoobQ is responsible for managing jobs that encounter errors during execution.
  # This fail handler provides robust retry logic with exponential backoff, detailed logging, and dead letter queue
  # management to ensure reliability and traceability of job failures.
  #
  # ## Key Features
  #
  # ### 1. Enhanced Logging
  #
  # The `FailHandler` includes more detailed logging capabilities:
  # - Logs error details when a job is dead, including job ID, queue name, start time, error message, and stack trace.
  # - Logs retry attempts with job ID and retry delay information.
  # - Logs when a job is moved to the dead letter queue after exhausting retry attempts.
  #
  # ### 2. Retry Logic with Exponential Backoff
  #
  # The `FailHandler` will retry jobs up to a specified maximum number of retries (`job.retries`). The retry
  # delay is calculated using an exponential backoff strategy to avoid overwhelming the system:
  # - Base delay starts at 2 seconds.
  # - Retry delay increases exponentially, with a maximum cap of 5 minutes to avoid excessively long delays.
  #
  # ### 3. Dead Letter Queue Handling
  #
  # When a job exhausts its retry attempts, it is moved to a "dead letter" queue for further inspection and
  # manual intervention:
  #
  # - The `mark_as_dead` method is called to track jobs that could not be processed successfully.
  # - This ensures that problematic jobs are not lost and can be debugged later.
  #
  # ## Usage
  #
  # The `FailHandler` is automatically invoked when a job execution fails:
  # ```
  # JoobQ::FailHandler.call(job, start_time, exception, queue)
  # ```
  # The method takes four parameters:
  # - `job`: The job that failed.
  # - `start_time`: The time when the job started.
  # - `exception`: The exception that caused the failure.
  # - `queue`: The queue that the job belongs to.
  #
  # ## Exponential Backoff Calculation
  # The backoff is calculated using the formula:
  # ```
  # (2 ** retry_count) * base_delay
  # ```
  # - **Base Delay**: The initial delay is set to 2 seconds (2000 milliseconds).
  # - **Maximum Delay**: Capped at 5 minutes (300,000 milliseconds) to prevent unreasonably long waits between retries.
  #
  # ## Logging Examples
  # - **Job Execution Failed**:
  #   ```
  #   [FAIL_HANDLER] Job Execution Failed: job_id=123, queue=critical_jobs, start_time=2024-11-15T08:00:00Z,
  #   error_message=Some error occurred, stack_trace=...
  #   ```
  # - **Retrying Job**:
  #   ```
  #   [FAIL_HANDLER] Retrying Job: job_id=123, retry_delay=4000ms
  #   ```
  # - **Job Moved to Dead Letter Queue**:
  #   ```
  #   [FAIL_HANDLER] Job Moved to Dead Letter Queue: job_id=123
  #   ```
  #
  # ## Configuration
  # - **Maximum Retries**: Defined by the `job.retries` property. Customize this value based on the
  #   reliability needs of your system.
  # - **Base and Maximum Delay**: Adjust the `base_delay` and `delay` values in the `exponential_backoff`
  #   method if you need different retry behavior.
  #
  # ## Future Improvements
  #
  # - **Customizable Backoff Strategy**: Allow developers to choose different backoff strategies (e.g., linear,
  #   exponential with jitter).
  # - **Notification Mechanism**: Add support for sending notifications (e.g., email, Slack) when jobs are
  #   moved to the dead letter queue.
  #
  class FailHandler(T)
    def initialize(@queue : BaseQueue, @metrics : Metrics)
    end

    def handle_failure(job : T, ex : Exception)
      Log.error &.emit("Job Failure", job_id: job.jid.to_s, error: ex.message)
      job.failed!
      job.retries -= 1

      if job.retries > 0
        @metrics.increment_retried
        job.retrying!
        ExponentialBackoff.retry(job, @queue)
      else
        error = {
          job:       job.to_json,
          queue:     job.queue,
          failed_at: Time.local,
          message:   ex.message,
          backtrace: ex.inspect_with_backtrace[0..10],
          cause:     ex.cause.to_s,
        }
        @metrics.increment_dead
        DeadLetterManager.add(job, @queue, error)
      end
    end
  end

  class ExponentialBackoff
    def self.retry(job, queue)
      if job.retries > 0
        delay = (2 ** (job.retries)) * 1000 # Delay in ms
        # Logic to add the job back to the queue after a delay
        queue.store.schedule(job, delay)
        # Log.warn &.emit("Job moved to Retry Queue", job_id: job.jid.to_s)
      end
    end
  end

  module DeadLetterManager
    def self.add(job, queue, error = nil)
      DeadLetter.add job
      # Log.error &.emit("Job moved to Dead Letter Queue", error: error)
    end
  end
end
