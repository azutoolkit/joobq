module JoobQ
  # The `Store` class in the [`JoobQ`](JoobQ ) module defines a generic interface for job storage and retrieval. It
  # provides methods for managing job queues, including enqueuing, dequeuing, scheduling, and marking jobs as failed or
  # dead. This abstract class must be implemented by concrete storage backends.
  #
  # ### Methods
  #
  # #### `clear_queue`
  #
  # ```
  # abstract def clear_queue(queue_name : String) : Nil
  # ```
  #
  # Clears all jobs from the specified queue.
  #
  # #### `delete_job`
  #
  # ```
  # abstract def delete_job(job : JoobQ::Job) : Nil
  # ```
  #
  # Deletes the specified job from the store.
  #
  # #### `enqueue`
  #
  # ```
  # abstract def enqueue(job : JoobQ::Job) : String
  # ```
  #
  # Enqueues the specified job and returns a unique job ID.
  #
  # #### `dequeue`
  #
  # ```
  # abstract def dequeue(queue_name : String, klass : Class) : Job?
  # ```
  #
  # Dequeues the next job from the specified queue and returns it.
  #
  # #### `move_job_back_to_queue`
  #
  # ```
  # abstract def move_job_back_to_queue(queue_name : String) : Bool
  # ```
  #
  # Moves a job back to the queue if it was being processed but not completed.
  #
  # #### `mark_as_failed`
  #
  # ```
  # abstract def mark_as_failed(job : JoobQ::Job, error_details : Hash) : Nil
  # ```
  #
  # Marks the specified job as failed with the provided error details.
  #
  # #### `mark_as_dead`
  #
  # ```
  # abstract def mark_as_dead(job : JoobQ::Job, expiration_time : String) : Nil
  # ```
  #
  # Marks the specified job as dead with the provided expiration time.
  #
  # #### `schedule`
  #
  # ```
  # abstract def schedule(job : JoobQ::Job, delay_in_ms : Int64) : Nil
  # ```
  #
  # Schedules the specified job to be executed after the given delay in milliseconds.
  #
  # #### `fetch_due_jobs`
  #
  # ```
  # abstract def fetch_due_jobs(current_time : Time) : Array(String)
  # ```
  #
  # Fetches jobs that are due to be executed at the specified current time.
  #
  # #### `queue_size`
  #
  # ```
  # abstract def queue_size(queue_name : String) : Int64
  # ```
  #
  # Returns the size of the specified queue.
  #
  # #### `list_jobs`
  #
  # ```
  # abstract def list_jobs(queue_name : String, page_number : Int32 = 1, page_size : Int32 = 200) : Array(String)
  # ```
  #
  # Lists jobs in the specified queue with pagination support.
  #
  # ### Usage
  #
  # To use the `Store` class, you need to implement it in a concrete storage backend.
  #
  # ### Workflow
  #
  # 1. **Initialization**:
  #    - Implement the `Store` class in a concrete storage backend.
  #    - Initialize the store instance.
  #
  # 2. **Managing Jobs**:
  #    - Use `enqueue` to add jobs to the queue.
  #    - Use `dequeue` to fetch and remove the next job from the queue.
  #    - Use `schedule` to delay job execution.
  #    - Use `mark_as_failed` and `mark_as_dead` to handle job failures and expirations.
  #    - Use `clear_queue` and `delete_job` to manage job cleanup.
  #
  # 3. **Fetching Jobs**:
  #    - Use `fetch_due_jobs` to retrieve jobs that are due for execution.
  #    - Use `queue_size` and `list_jobs` to monitor and list jobs in the queue.
  #
  # ### Example
  #
  # Here is a complete example demonstrating how to implement and use the `Store` class:
  #
  # ```
  # require "joobq"
  #
  # # Define a job
  # struct ExampleJob
  #   include JoobQ::Job
  #   property x : Int32
  #
  #   def initialize(@x : Int32)
  #   end
  #
  #   def perform
  #     puts "Performing job with x = #{x}"
  #   end
  # end
  #
  #
  # This example demonstrates how to implement an in-memory store, enqueue a job, and dequeue and perform the job.
  abstract class Store
    abstract def clear_queue(queue_name : String) : Nil
    abstract def delete_job(job : String) : Nil
    abstract def enqueue(job : JoobQ::Job) : String
    abstract def dequeue(queue_name : String, klass : Class) : String?
    abstract def claim_job(queue_name : String, worker_id : String, klass : Class) : String?
    abstract def claim_jobs_batch(queue_name : String, worker_id : String, klass : Class, batch_size : Int32) : Array(String)
    abstract def release_job_claim(queue_name : String, worker_id : String) : Nil
    abstract def release_job_claims_batch(queue_name : String, worker_id : String, job_count : Int32) : Nil
    abstract def move_job_back_to_queue(queue_name : String) : Bool
    abstract def mark_as_dead(job : JoobQ::Job, expiration_time : Int64) : Nil
    abstract def schedule(job : JoobQ::Job, delay_in_ms : Int64, delay_set : String) : Nil
    abstract def schedule_job(job : String, schedule_time : Int64) : Nil
    abstract def fetch_due_jobs(current_time : Time, delay_set : String, limit : Int32, remove : Bool) : Array(String)
    abstract def queue_size(queue_name : String) : Int64
    abstract def list_jobs(queue_name : String, page_number : Int32 = 1, page_size : Int32 = 200) : Array(String)
    abstract def enqueue_batch(jobs : Array(JoobQ::Job), batch_size : Int32) : Nil
    abstract def cleanup_job(job_json : String, queue_name : String) : Nil
    abstract def mark_job_completed(job_json : String, queue_name : String) : Nil
    abstract def verify_job_removed_from_processing?(job_id : String, queue_name : String) : Bool
    abstract def processing_queue_size(queue_name : String) : Int64
    abstract def cleanup_jobs_batch(job_jsons : Array(String), queue_name : String) : Nil
  end
end
