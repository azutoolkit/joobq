module JoobQ
  # ### Module `JoobQ::Job`
  #
  # This module is designed to be mixed into specific job classes, providing them with serialization
  # capabilities and queue-related methods. It's meant for defining jobs that can be pushed to and
  # handled by the `JoobQ` queue system.
  #
  # #### Mixin `included` Macro
  #
  # When included in a class, this macro endows the class with the following properties and methods:
  #
  # - **JSON Serialization**: Includes `JSON::Serializable` for easy serialization and deserialization of job instances.
  #
  # - **Configuration Constants**:
  #   - `CONFIG`: A constant set to `Configure.instance`, representing the job configuration.
  #
  # - **Properties**:
  #   - `jid`: A unique identifier for the job, generated using `UUID.random`.
  #   - `queue`: The name of the queue to which the job will be pushed. Defaults to `CONFIG.default_queue`.
  #   - `retries`: The number of times the job should be retried. Defaults to `CONFIG.retries`.
  #   - `expires`: The expiration time for the job. Defaults to `CONFIG.expires`.
  #   - `at`: An optional `Time` indicating when the job should be executed. Initially `nil`.
  #
  # - **Class Methods**:
  #   - `perform`: Creates a new instance of the job and pushes it to the queue. Overloaded to
  #     accept arguments for initializing the job.
  #   - `delay(for wait_time : Time::Span, **args)`: Schedules the job to be performed after a
  #     specified `wait_time`. Returns the job's `jid`.
  #   - `schedule(every : Time::Span, **args)`: Schedules the job to run at regular intervals specified by `every`.
  #
  # #### Abstract Instance Method
  #
  # - `perform`: An abstract instance method that must be implemented by the including class. This method defines
  # what the job does when executed.
  #
  # ### Usage Example
  #
  # ```
  # class MyJob
  #   include JoobQ::Job
  #
  #   def perform
  #     # Define what the job does here
  #   end
  # end
  #
  # # Pushing the job to the queue immediately
  # MyJob.perform
  #
  # # Scheduling the job to be performed after 5 minutes
  # MyJob.delay(for: 5.minutes)
  #
  # # Scheduling the job to run every hour
  # MyJob.schedule(every: 1.hour)
  # ```
  #
  # ### Notes
  #
  # - The `Job` module requires the including class to implement the `perform` method,
  #   which defines the job's functionality.
  # - Jobs can be queued for immediate execution, delayed execution, or scheduled at regular intervals.
  # - The module leverages the functionality of the `JoobQ` module for managing job queues and scheduling.
  #
  module Job
    macro included
      include JSON::Serializable
      include Comparable({{@type}})

      enum Status
        Enqueued
        Delayed
        Running
        Completed
        Failed
      end

      {% for status in Status %}
        # Methods for checking
        def {{status.id}}?
          status == Status.{{status.id}}
        end

        # Methods for setting status
        def {{status.id}}!
          self.status = Status.{{status.id}}
        end
      {% end %}


      # The Unique identifier for this job
      getter jid : UUID = UUID.random
      property queue : String = JoobQ.config.default_queue
      property retries : Int32 = JoobQ.config.retries
      property expires : Int32 = JoobQ.config.expires.total_seconds.to_i
      property at : Time? = nil
      property status : String = Status::Enqueued

      def self.perform
        JoobQ.push new
      end

      def self.perform(**args)
        JoobQ.push new(**args)
      end

      def self.delay(for wait_time : Time::Span, **args)
        ts = Time.local + wait_time
        job = new(**args)
        job.delayed!
        job.at = ts if ts > Time.local
        JoobQ.scheduler.delay(job, wait_time)
        job.jid
      end

      # Allows for scheduling Jobs at an interval time span.
      #
      # ```crystal
      # TestJob.run(every: 1.second, x: 1)
      # ```
      def self.schedule(every : Time::Span, **args)
        JoobQ.scheduler.every every, self, **args
      end
    end

    abstract def perform
  end
end
