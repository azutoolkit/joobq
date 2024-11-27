module JoobQ
  class InMemoryStore < Store
    record ScheduledJob, job : JoobQ::Job, execute_at : Time
    record FailedJob, job : JoobQ::Job
    record DeadJob, job : JoobQ::Job, expiration_time : Int64

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
    def delete_job(job : String) : Nil
      job_json = JSON.parse(job)
      queue_name = job_json["queue"].as_s
      @queues[queue_name].each do |entry|
        @queues[queue_name].delete(entry) if entry.to_json == job
      end
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

    def enqueue_batch(jobs : Array(JoobQ::Job), batch_size : Int32 = 1000) : Nil
      raise "Batch size must be greater than 0" if batch_size <= 0
      raise "Batch size must be less than or equal to 1000" if batch_size > 1000

      jobs.each_slice(batch_size) do |batch_jobs|
        batch_jobs.each do |job|
          enqueue(job)
        end
      end
    end

    # Dequeues the next job from the specified queue
    def dequeue(queue_name : String, klass : Class) : String?
      return nil unless @queues.has_key?(queue_name)
      item = @queues[queue_name].shift
      item.to_json if item
    end

    # Moves a job back to the queue if it was being processed but not completed
    def move_job_back_to_queue(queue_name : String) : Bool
      job = @queues[queue_name].shift
      return false unless job

      @queues[queue_name] << job
      true
    end

    # Marks a job as dead with an expiration time
    def mark_as_dead(job : JoobQ::Job, expiration_time : Int64) : Nil
      @dead_jobs << DeadJob.new(job: job, expiration_time: expiration_time)
    end

    # Schedules a job for execution after a specified delay
    def schedule(job : JoobQ::Job, delay_in_ms : Int64, delay_set : String = "") : Nil
      execute_at = Time.local + (delay_in_ms / 1000).seconds
      @scheduled_jobs << ScheduledJob.new(job: job, execute_at: execute_at)
    end

    # Fetches jobs that are due for execution
    def fetch_due_jobs(
      current_time = Time.local,
      delay_set : String = "scheduled_jobs",
      limit : Int32 = 50,
      remove : Bool = true
    ) : Array(String)
      due_jobs = @scheduled_jobs.select { |entry| entry.execute_at <= current_time }
      due_jobs.each { |entry| @scheduled_jobs.delete(entry) } if remove
      due_jobs.map(&.job.to_json)
    end

    # Gets the size of the specified queue
    def set_size(queue_name : String) : Nil
      queue_size(queue_name)
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

    def processing_list(pattern : String = "", limit : Int32 = 100) : Array(String)
      puts "Processing list called with pattern: #{pattern}"
      @queues.select.flat_map do |_, value|
        value.map(&.to_json)
      end.flatten[0...limit]
    end
  end
end
