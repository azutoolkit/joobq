module JoobQ
  # JoobQ::Job Module
  #
  # The `JoobQ::Job` module provides an abstract structure for defining jobs
  # within the JoobQ asynchronous job processing framework. This module includes
  # functionality for managing job statuses, scheduling, retries, timeouts, and more.
  #
  # ## Example Usage
  #
  # To define a custom job, include the `JoobQ::Job` module within your job class
  # and implement the `perform` method.
  #
  # ```
  # class ExampleJob
  #   include JoobQ::Job
  #
  #   def perform
  #     puts "Executing job logic"
  #   end
  # end
  # ```
  #
  # You can then enqueue, delay, or schedule the job using provided methods.
  #
  # ### Job Status
  # The `JoobQ::Job::Status` enum defines the possible states for a job:
  # - `Pending`: The job has been created but not scheduled.
  # - `Scheduled`: The job is scheduled to run at a specific time.
  # - `Running`: The job is currently executing.
  # - `Completed`: The job finished successfully.
  # - `Retrying`: The job is retrying after a failure.
  # - `Failed`: The job execution failed after exhausting retries.
  # - `Expired`: The job expired before execution.
  #
  # Each status has corresponding predicate and setter methods for checking
  # and updating job status.
  #
  # ### Properties
  #
  # - `jid`: The unique identifier for the job (UUID).
  # - `queue`: The queue to which the job is assigned.
  # - `retries`: The maximum number of retries allowed.
  # - `expires`: The expiration time of the job in Unix milliseconds.
  # - `at`: Optional time for delayed job execution.
  # - `status`: The current status of the job.
  # - `timeout`: The maximum execution time allowed for the job.
  #
  # ### Methods
  #
  # #### Status Predicate and Setter Methods
  #
  # The module automatically defines predicate and setter methods for each job
  # status:
  #
  # ```
  # job = ExampleJob.new
  # job.running! # Sets the job's status to Running
  # job.running? # Checks if the job's status is Running
  # ```
  #
  # #### Enqueue and Execution Methods
  #
  # - `batch_enqueue(jobs : Array({{type}}))`: Enqueues an array of jobs.
  #
  #   ```
  # ExampleJob.batch_enqueue([job1, job2, job3])
  #   ```
  #
  # - `enqueue(**args)`: Enqueues a single job to the queue.
  #
  #   ```
  # ExampleJob.enqueue(param: "value")
  #   ```
  #
  # - `perform`: Executes the job immediately without enqueuing.
  #
  #   ```
  # ExampleJob.perform(param: "value")
  #   ```
  #
  # #### Delay and Scheduling
  #
  # - `enqueue_at(time : Time::Span, **args)`: Enqueues a job to be processed after a specified delay.
  #
  #   ```
  # ExampleJob.enqueue_at(1.minute, param: "value")
  #   ```
  #
  # - `delay(for wait_time : Time::Span, **args)`: Delays job execution by a specified timespan.
  #
  #   ```
  # ExampleJob.delay(2.minutes, param: "value")
  #   ```
  #
  # - `schedule(every : Time::Span, **args)`: Schedules a recurring job to run at a specified interval.
  #
  #   ```
  # ExampleJob.schedule(5.seconds, param: "value")
  #   ```
  #
  # #### Timeout Handling
  #
  # `with_timeout` provides a way to enforce a timeout on the job's execution.
  # If the block takes longer than the specified `@timeout`, it raises a `Timeout::TimeoutError`.
  #
  # ```
  # def perform
  #   with_timeout do
  #     # Simulate a long-running task
  #     puts "Starting a task that should timeout..."
  #     sleep 10.seconds
  #   rescue Timeout::TimeoutError => e
  #     puts e.message # => "execution expired after 5 seconds"
  #   end
  # end
  # ```
  #
  module Job
    enum Status
      Completed
      Enqueued
      Expired
      Failed
      Retrying
      Running
      Scheduled
    end

    macro included
      include Comparable({{@type}})
      include JSON::Serializable
      extend JSON::Schema
      # The Unique identifier for this job
      getter jid : UUID = UUID.random
      property queue : String = JoobQ.config.default_queue
      property retries : Int32 = JoobQ.config.retries
      property expires : Int64 = JoobQ.config.expires.from_now.to_unix_ms
      property at : Time? = nil
      property status : Status = Status::Enqueued


      {% for status in Status.constants %}
        # Methods for checking
        def {{status.downcase}}?
          @status == Status::{{status.id}}
        end

        # Methods for setting status
        def {{status.downcase}}!
          @status = Status::{{status.id}}
        end
      {% end %}

      # Batch enqueue jobs in an array of jobs
      # ```
      # TestJob.batch_enqueue([job1, job2, job3])
      # ```
      def self.batch_enqueue(jobs : Array({{@type}}))
        jobs.each do |job|
          JoobQ.add job
        end
      end

      # Enqueue a job to the queue for processing
      #
      # ```
      # TestJob.enqueue(x: 1)
      # ```
      def self.enqueue(**args)
        JoobQ.add new(**args)
      end

      # Execute the job immediately does not enqueue the job
      #
      # ```
      # TestJob.enqueue(x: 1)
      # ```
      def self.perform
        new.perform
      end

      # Execute the job immediately does not enqueue the job
      #
      # ```
      # TestJob.perform(x: 1)
      # ```
      def self.perform(**args)
        new(**args).perform
      end

      # Delay a job for a specific time span and enqueue it
      # ```
      # TestJob.delayed(time: 1.minute, x: 1)
      # ```
      def self.enqueue_at(time : Time::Span, **args)
        delayed(time, **args)
      end

      # Delay a job for a specific time span and enqueue it
      # ```
      # TestJob.delayed(time: 1.minute, x: 1)
      # ```
      def self.delay(for wait_time : Time::Span, **args)
        ts = Time.local + wait_time
        job = new(**args)
        job.scheduled!
        job.at = ts if ts > Time.local
        JoobQ.scheduler.delay(job, wait_time)
        job.jid
      end

      # Allows for scheduling Jobs at an interval time span.
      #
      # ```
      # TestJob.run(every: 1.second, x: 1)
      # ```
      def self.schedule(every : Time::Span, **args)
        JoobQ.scheduler.every every, self, **args
      end
    end

    abstract def perform

    # With timeout method to run a block of code with a timeout limit set
    #
    # ```
    # @timeout = 5.seconds
    #
    # with_timeout do
    #   # Simulate a long-running task
    #   puts "Starting a task that should timeout..."
    #   sleep 10.seconds
    #   puts "This should not print because the task should be timed out"
    # rescue Timeout::TimeoutError => e
    #   puts e.message # => "execution expired after 5 seconds"
    # end
    # ```
    def with_timeout(timeout : Time::Span = JoobQ.config.timeout, &block : ->)
      Timeout.run(timeout) do
        block.call
      end
    end

    def <=>(other : T)
      self.jid <=> other.jid
    end
  end
end
