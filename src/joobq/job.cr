module JoobQ
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
  #
  # The `JoobQ::Job::Status` enum defines the possible states for a job:
  # - `Enqueued`: The job has been enqueued and is waiting to be processed.
  # - `Scheduled`: The job is scheduled to run at a specific time.
  # - `Running`: The job is currently executing.
  # - `Completed`: The job finished successfully.
  # - `Retrying`: The job is retrying after a failure.
  # - `Dead`: The job execution failed after exhausting retries.
  # - `Expired`: The job expired before execution.
  #
  # Each status has corresponding predicate and setter methods for checking
  # and updating job status.
  #
  # ### Properties
  #
  # - `jid`: The unique identifier for the job (UUID).
  # - `queue`: The queue to which the job is assigned.
  # - `retries`: The number of retries remaining for this job.
  # - `max_retries`: The maximum number of retries allowed (set at job creation).
  # - `expires`: The expiration time of the job in Unix milliseconds.
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
  # ```
  # ExampleJob.batch_enqueue([job1, job2, job3])
  # ```
  #
  # - `enqueue(**args)`: Enqueues a single job to the queue.
  #
  # ```
  # ExampleJob.enqueue(param: "value")
  # ```
  #
  # - `perform`: Executes the job immediately without enqueuing.
  #
  # ```
  # ExampleJob.perform(param: "value")
  # ```
  #
  # #### Delay and Scheduling
  #
  # - `enqueue_at(time : Time::Span, **args)`: Enqueues a job to be processed after a specified delay.
  #
  # ```
  # ExampleJob.enqueue_at(1.minute, param: "value")
  # ```
  #
  # - `delay(for wait_time : Time::Span, **args)`: Delays job execution by a specified timespan.
  #
  # ```
  # ExampleJob.delay(2.minutes, param: "value")
  # ```
  #
  # - `schedule(every : Time::Span, **args)`: Schedules a recurring job to run at a specified interval.
  #
  # ```
  # ExampleJob.schedule(5.seconds, param: "value")
  # ```
  #
  module Job
    enum Status
      Completed
      Dead
      Enqueued
      Expired
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
      property max_retries : Int32 = JoobQ.config.retries
      property expires : Int64 = JoobQ.config.expires.from_now.to_unix_ms
      property status : Status = Status::Enqueued

      @[JSON::Field(emit_null: true)]
      property error : NamedTuple(
        failed_at: String,
        message: String | Nil,
        backtrace: String,
        cause: String,
        error_type: String?,
        error_class: String?,
        retry_count: Int32?,
        system_context: Hash(String, String)?
      )?

      @[JSON::Field(ignore: true)]
      property enqueue_time = Time.monotonic

      macro finalized
        # Register the job type with QueueFactory for YAML-based queue creation
        # This allows queues to be created from configuration files
        #
        # Note: In Crystal, finalized macros may not execute reliably for registration.
        # For applications using YAML configuration, explicitly register job types:
        #   QueueFactory.register_job_type(MyJob)
        #
        # For programmatic queue creation, registration happens automatically via Configure.queue macro
        {% job_name = @type.id.stringify %}
        ::JoobQ::QueueFactory.add_to_registry(
          {{job_name}},
          ->(name : String, workers : Int32, throttle : NamedTuple(limit: Int32, period: Time::Span)?) {
            ::JoobQ::Queue({{@type.id}}).new(name, workers, throttle).as(::JoobQ::BaseQueue)
          },
          ->(registry : ::JoobQ::JobSchemaRegistry) {
            registry.register({{@type.id}})
          }
        )
      end

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
      def self.batch_enqueue(jobs : Array({{@type}}), batch_size : Int32 = 1000) : Nil
        raise "Batch size must be greater than 0" if batch_size <= 0
        raise "Batch size must be less than or equal to 1000" if batch_size > 1000
        JoobQ.store.enqueue_batch(jobs)
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
        job = new(**args)
        job.scheduled!
        JoobQ::DelayedJobScheduler.new.delay(job: job, delay_time: wait_time)
        job.jid
      end

      # Allows for scheduling Jobs at an interval time span.
      #
      # ```
      # TestJob.run(every: 1.second, x: 1)
      # ```
      def self.schedule(every : Time::Span, **args)
        JoobQ::RecurringJobScheduler.instance.every(every, self, **args)
      end
    end

    abstract def perform

    def <=>(other)
      self.jid <=> other.jid
    end
  end
end
