module JoobQ
  class InMemoryStore < Store
    record ScheduledJob, job : JoobQ::Job, execute_at : Time
    record FailedJob, job : JoobQ::Job, error_details : Hash(String, String)
    record DeadJob, job : JoobQ::Job, expiration_time : Time

    getter queues : Hash(String, Array(JoobQ::Job))
    getter scheduled_jobs : Array(ScheduledJob)
    getter failed_jobs : Array(FailedJob)
    getter dead_jobs : Array(DeadJob)

    def initialize
      @queues = Hash(String, Array(JoobQ::Job)).new
      @scheduled_jobs = [] of ScheduledJob
      @failed_jobs = [] of FailedJob
      @dead_jobs = [] of DeadJob
    end

    def reset
      @queues.clear
      @scheduled_jobs.clear
      @failed_jobs.clear
      @dead_jobs.clear
    end

    # Clears all jobs from the specified queue
    def clear_queue(queue_name : String) : Nil
      @queues[queue_name].clear
    end

    # Deletes a specific job from the store
    def delete_job(job : JoobQ::Job) : Nil
      @queues[job.queue].delete(job)
      @scheduled_jobs.reject! { |entry| entry.job == job }
    end

    # Enqueues a job in the specified queue and returns a unique ID
    def enqueue(job : JoobQ::Job) : String
      unless @queues.has_key?(job.queue)
        puts "Creating queue #{job.queue}"
        @queues[job.queue] = [] of JoobQ::Job
      end

      @queues[job.queue] << job
      job.jid.to_s
    end

    # Dequeues the next job from the specified queue
    def dequeue(queue_name : String, klass : Class) : JoobQ::Job?
      return nil unless @queues.has_key?(queue_name)
      @queues[queue_name].shift
    end

    # Moves a job back to the queue if it was being processed but not completed
    def move_job_back_to_queue(queue_name : String) : Bool
      job = @queues[queue_name].shift
      return false unless job

      @queues[queue_name] << job
      true
    end

    # Marks a job as failed with error details
    def mark_as_failed(job : JoobQ::Job, error_details : Hash(String, String)) : Nil
      @failed_jobs << FailedJob.new(job: job, error_details: error_details)
    end

    # Marks a job as dead with an expiration time
    def mark_as_dead(job : JoobQ::Job, expiration_time : String) : Nil
      expiration_time_parsed = Time.parse_rfc3339(expiration_time)
      @dead_jobs << DeadJob.new(job: job, expiration_time: expiration_time_parsed)
    end

    # Schedules a job for execution after a specified delay
    def schedule(job : JoobQ::Job, delay_in_ms : Int64) : Nil
      execute_at = Time.local + (delay_in_ms / 1000).seconds
      @scheduled_jobs << ScheduledJob.new(job: job, execute_at: execute_at)
    end

    # Fetches jobs that are due for execution
    def fetch_due_jobs(current_time : Time) : Array(String)
      due_jobs = @scheduled_jobs.select { |entry| entry.execute_at <= current_time }
      due_jobs.each { |entry| @scheduled_jobs.delete(entry) }
      due_jobs.map(&.job.to_json)
    end

    # Returns the size of the specified queue
    def queue_size(queue_name : String) : Int64
      return 0_i64 unless @queues.has_key?(queue_name)
      @queues[queue_name].size.to_i64
    end

    # Lists jobs in a queue with pagination
    def list_jobs(queue_name : String, page_number : Int32 = 1, page_size : Int32 = 200) : Array(String)
      start_index = (page_number - 1) * page_size
      return [] of String unless @queues.has_key?(queue_name)
      @queues[queue_name][start_index...(start_index + page_size)].map(&.to_json)
    end
  end
end
