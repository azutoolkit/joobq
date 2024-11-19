module JoobQ
  # The `Worker` class is responsible for executing jobs from a queue. Each worker runs in a separate fiber, fetching
  # jobs from the queue, executing them, and handling job completion or failure. Workers can be started, stopped,
  # and monitored for activity.
  #
  # ### Properties
  #
  # - `wid : Int32` - The worker ID.
  # - `active : Bool` - Indicates whether the worker is currently active.
  # - `@last_job_time : Int64` - The timestamp of the last job execution.
  # - `@terminate : Channel(Nil)` - Channel used to signal worker termination.
  # - `@queue : Queue(T)` - The queue from which the worker fetches jobs.
  #
  # ### Methods
  #
  # #### `initialize`
  #
  # ```
  # def initialize(@wid : Int32, @terminate : Channel(Nil), @queue : Queue(T))
  # ```
  #
  # Initializes the worker with a worker ID, termination channel, and queue.
  #
  # #### `name`
  #
  # ```
  # def name
  # ```
  #
  # Returns the name of the queue the worker is associated with.
  #
  # #### `stop!`
  #
  # ```
  # def stop!
  # ```
  #
  # Signals the worker to stop by sending a message through the termination channel.
  #
  # #### `run`
  #
  # ```
  # def run
  # ```
  #
  # Starts the worker in a new fiber. The worker enters a loop where it fetches and executes jobs from the queue until it receives a termination signal.
  #
  # ### Usage
  #
  # #### Creating and Starting a Worker
  #
  # To create and start a worker, you need to initialize it with a worker ID, termination channel, and queue, and then call the `run` method:
  #
  # ```
  # terminate_channel = Channel(Nil).new
  # queue = JoobQ::Queue(ExampleJob).new("example", 10)
  # worker = JoobQ::Worker(ExampleJob).new(1, terminate_channel, queue)
  # worker.run
  # ```
  #
  # #### Stopping a Worker
  #
  # To stop a worker, call the `stop!` method:
  #
  # ```
  # worker.stop!
  # ```
  #
  # ### Workflow
  #
  # 1. **Initialization**:
  #    - The worker is initialized with a worker ID, termination channel, and queue.
  #    - The `@last_job_time` is set to the current time in milliseconds.
  #
  # 2. **Starting the Worker**:
  #    - The `run` method is called to start the worker in a new fiber.
  #    - The worker sets its `active` property to `true` and enters a loop.
  #
  # 3. **Job Execution**:
  #    - Inside the loop, the worker fetches the next job from the queue using `@queue.next_job`.
  #    - If a job is fetched, it is marked as running.
  #    - The worker checks if the job has expired. If expired, it is moved to the dead letter queue.
  #    - If the job is valid, the worker executes the job's `perform` method.
  #    - After execution, the job is marked as completed or retried based on the outcome.
  #
  # 4. **Stopping the Worker**:
  #    - The worker listens for a termination signal on the `@terminate` channel.
  #    - When a termination signal is received, the worker sets its `active` property to `false` and exits the loop.
  #
  # ### Example
  #
  # Here is a complete example demonstrating how to create, start, and stop a worker:
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
  # # Configure the queue
  # JoobQ.configure do
  #   queue "example", 10, ExampleJob
  # end
  #
  # # Get the queue instance
  # queue = JoobQ["example"]
  #
  # # Add jobs to the queue
  # 10.times do |i|
  #   queue.add(ExampleJob.new(x: i).to_json)
  # end
  #
  # # Create and start a worker
  # terminate_channel = Channel(Nil).new
  # worker = JoobQ::Worker(ExampleJob).new(1, terminate_channel, queue)
  # worker.run
  #
  # # Stop the worker after some time
  # sleep 10
  # worker.stop!
  # ```
  #
  # This example sets up a queue, adds jobs to the queue, creates a worker, starts the worker, and stops the
  # worker after 10 seconds.
  class Worker(T)
    Log = ::Log.for("WORKER")

    getter wid : Int32
    property? active : Bool = false

    @last_job_time : Int64

    def initialize(@wid : Int32, @terminate : Channel(Nil), @queue : Queue(T))
      @last_job_time = Time.utc.to_unix_ms
    end

    def name
      @queue.name
    end

    def stop!
      @terminate.send nil
    end

    def run
      return if active?
      @active = true
      spawn do
        begin
          loop do
            select
            when @terminate.receive?
              @active = false
              break
            else
              if job = @queue.next_job
                job.running!

                if job.expires && Time.utc.to_unix_ms > job.expires
                  job.expired!
                  DeadLetterManager.add(job, @queue)
                  next
                end

                throttle if @queue.throttle_limit
                @queue.busy.add(1)
                execute job
                @queue.busy.sub(1)
              end
            end
          end
        rescue ex : Exception
          Log.error &.emit("Fetch", worker_id: wid, reason: ex.message)
          @queue.restart self, ex
        end
      end
    end

    # Throttles the worker based on the throttle limit set on the queue. The worker sleeps for the required time to
    # ensure that the throttle limit is not exceeded. The throttle limit is the maximum number of jobs that can be
    # processed per second. The worker calculates the minimum interval between jobs based on the throttle limit and
    # sleeps for the required time if necessary. The worker keeps track of the last job execution time to calculate
    # the elapsed time between jobs.
    #
    # The throttle method is called before executing each job to ensure that the worker does not exceed the throttle
    # limit.
    private def throttle
      if throttle_config = @queue.throttle_limit
        limit = throttle_config[:limit]
        period = throttle_config[:period].total_milliseconds
        min_interval = period / limit # milliseconds
        now = Time.utc.to_unix_ms
        elapsed = now - @last_job_time
        sleep_time = min_interval - elapsed
        if sleep_time > 0
          sleep (sleep_time / 1000.0).seconds
          @last_job_time = Time.utc.to_unix_ms
        else
          @last_job_time = now
        end
      end
    end

    private def execute(job : T)
      wait_time = Time.monotonic - job.enqueue_time
      @queue.total_job_wait_time += wait_time
      start = Time.monotonic
      job.perform
      job.completed!
      @queue.total_job_execution_time = Time.monotonic - start
      @queue.completed.add(1)
      @queue.store.delete_job job
    rescue ex : Exception
      FailHandler.call job, start, ex, @queue
    end
  end
end
