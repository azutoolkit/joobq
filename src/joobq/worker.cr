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
  # #### `terminate`
  #
  # ```
  # def terminate
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
  # To stop a worker, call the `terminate` method:
  #
  # ```
  # worker.terminate
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
  # worker.terminate
  # ```
  #
  # This example sets up a queue, adds jobs to the queue, creates a worker, starts the worker, and stops the
  # worker after 10 seconds.
  # The Worker class is responsible for fetching and executing jobs from the queue.
  # It adheres to the Single Responsibility Principle by focusing solely on job execution.
  class Worker(T)
    Log = ::Log.for("WORKER")

    getter wid : Int32
    getter active : Atomic(Bool) = Atomic(Bool).new(false)

    @terminate_channel : Channel(Nil)
    @queue : BaseQueue
    @metrics : Metrics
    @throttler : Throttler?
    @fail_handler : FailHandler(T)

    def initialize(@wid : Int32, @terminate_channel : Channel(Nil), @queue : BaseQueue, @metrics : Metrics)
      @queue = queue
      @metrics = metrics
      @terminate_channel = terminate_channel
      @fail_handler = FailHandler(T).new(@queue, @metrics)
      if throttle_limit = @queue.throttle_limit
        @throttler = Throttler.new(throttle_limit)
      end
    end

    def name
      @queue.name
    end

    def active? : Bool
      active.get
    end

    def terminate
      active.set(false)
      @terminate_channel.send nil
    end

    def run
      return if active?
      active.set(true)
      spawn do
        begin
          loop do
            select
            when @terminate_channel.receive?
              active.set(false)
              break
            else
              if job = @queue.next_job
                handle_job job.as(T)
              else
                # No job available, sleep briefly to prevent tight loop
                sleep 0.1.seconds
              end
            end
          end
        rescue ex : Exception
          Log.error &.emit("Worker Error", worker_id: wid, reason: ex.message)
          @queue.worker_manager.restart self, ex
        end
      end
    end

    private def handle_job(job : T)
      job.running!

      if job.expired?
        job.expired!
        DeadLetterManager.add(job, @queue)
        return
      end

      throttle if @throttler

      @metrics.increment_busy
      execute job
      @metrics.decrement_busy
    end

    private def throttle
      @throttler.try &.throttle
    end

    private def execute(job : T)
      wait_time = Time.monotonic - job.enqueue_time
      @metrics.add_job_wait_time(wait_time)

      start_time = Time.monotonic
      begin
        job.perform
        job.completed!
        execution_time = Time.monotonic - start_time
        @metrics.add_job_execution_time(execution_time)
        @metrics.increment_completed
        @queue.delete_job job
      rescue ex : Exception
        execution_time = Time.monotonic - start_time
        @metrics.add_job_execution_time(execution_time)
        @fail_handler.handle_failure(job, ex)
      end
    end
  end
end
