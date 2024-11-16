module JoobQ
  abstract class BaseQueue
    abstract def add(job : String)
  end

  #  module is responsible for managing job queues. It handles job enqueuing, worker management,
  # job processing, and provides various metrics related to job execution. This class is generic and can
  # be instantiated with any job type.
  #
  # ### Properties
  #
  # - `store : Store` - The store instance used for job storage and retrieval.
  # - `name : String` - The name of the queue.
  # - `total_workers : Int32` - The total number of workers assigned to this queue.
  # - `jobs : String` - The job type as a string.
  # - `completed : Atomic(Int64)` - Counter for completed jobs.
  # - `retried : Atomic(Int64)` - Counter for retried jobs.
  # - `dead : Atomic(Int64)` - Counter for dead jobs.
  # - `busy : Atomic(Int64)` - Counter for busy jobs.
  # - `start_time : Time::Span` - The start time of the queue.
  # - `throttle_limit : Int32?` - Optional throttle limit for job processing.
  # - `terminate_channel : Channel(Nil)` - Channel used for terminating workers.
  # - `workers : Array(Worker(T))` - Array of workers assigned to this queue.
  # - `workers_mutex : Mutex` - Mutex for synchronizing worker operations.
  #
  # ## Job Execution Workflow
  #
  # 1. **Initialization**:
  # - When a `Queue` instance is created, it initializes with a name, total number of workers, and an optional
  #   throttle limit.
  # - The `create_workers` method is called to create the specified number of worker instances.
  #
  # 2. **Adding Jobs**:
  # - The `add` method is used to add jobs to the queue. It takes a JSON string representation of the job, parses
  #   it into the job type `T`, and enqueues it using the `store`.
  #
  # 3. **Starting the Queue**:
  # - The `start` method is called to start processing jobs in the queue.
  # - It first calls `reprocess_busy_jobs!` to move any jobs that were being processed but not completed back to
  #   the queue.
  # - Then, it iterates over the workers and calls their `run` method to start them.
  #
  # 4. **Worker Execution**:
  # - Each worker runs in a loop, fetching jobs from the queue and executing them.
  # - The worker marks the job as running, performs the job, and then marks it as completed.
  # - If the job has expired, it is moved to the dead letter queue.
  # - If an exception occurs during job execution, the job is retried or moved to the dead letter queue based on the
  #   retry logic.
  #
  # 5. **Job Metrics**:
  # - The queue maintains various metrics such as the number of completed, retried, dead, and busy jobs using atomic
  # counters.
  # - These metrics are updated as jobs are processed.
  #
  # ### Example Flow
  #
  # 1. **Initialize Queue**:
  # ```
  # queue = JoobQ::Queue(ExampleJob).new("example", 10)
  # ```
  #
  # 2. **Add Job**:
  # ```
  # queue.add(ExampleJob.new(x: 1).to_json)
  # ```
  #
  # 3. **Start Queue**:
  # ```
  # queue.start
  # ```
  #
  # 4. **Worker Fetches and Executes Job**:
  # - Worker fetches a job from the queue.
  # - Marks the job as running.
  # - Executes the job's `perform` method.
  # - Marks the job as completed or handles retries/dead letter queue if an error occurs.
  #
  # This flow ensures that jobs are processed asynchronously and reliably, with metrics tracking and error
  # handling in place.
  #
  # ### Methods
  #
  # #### `initialize`
  #
  # ```
  # def initialize(@name : String, @total_workers : Int32, @throttle_limit : Int32? = nil)
  # ```
  #
  # Initializes the queue with the given name, number of workers, and optional throttle limit.
  #
  # #### `parse_job`
  #
  # ```
  # def parse_job(job_data : JSON::Any)
  # ```
  #
  # Parses a job from JSON data.
  #
  # #### `start`
  #
  # ```
  # def start
  # ```
  #
  # Starts the queue by reprocessing busy jobs and running all workers.
  #
  # #### `add`
  #
  # ```
  # def add(job : String)
  # ```
  #
  # Adds a job to the queue by parsing it from a JSON string.
  #
  # ### Usage
  #
  # #### Defining a Queue
  #
  # To define a queue, you need to configure it using the `JoobQ.configure` method. Here is an example:
  #
  # ```
  # JoobQ.configure do
  #   queue "example", 10, ExampleJob
  # end
  # ```
  #
  # #### Adding Jobs to the Queue
  #
  # You can add jobs to the queue using the `add` method:
  #
  # ```
  # queue = JoobQ["example"]
  # queue.add(ExampleJob.new(x: 1).to_json)
  # ```
  #
  # #### Starting the Queue
  #
  # To start processing jobs in the queue, call the `start` method:
  #
  # ```
  # queue.start
  # ```
  #
  # ### Example
  #
  # Here is a complete example demonstrating how to define a queue, add jobs, and start the queue:
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
  # # Start the queue
  # queue.start
  # ```
  #
  # This example sets up a queue named "example" with 10 workers, adds 10 jobs to the queue, and starts processing the jobs.
  class Queue(T) < BaseQueue
    getter store : Store = JoobQ.config.store
    getter name : String
    getter total_workers : Int32
    getter jobs : String = T.to_s

    property completed : Atomic(Int64) = Atomic(Int64).new(0)
    property retried : Atomic(Int64) = Atomic(Int64).new(0)
    property dead : Atomic(Int64) = Atomic(Int64).new(0)
    property busy : Atomic(Int64) = Atomic(Int64).new(0)
    property start_time : Time::Span = Time.monotonic
    property throttle_limit : Int32? = nil

    # Use a Channel for job distribution
    private getter terminate_channel : Channel(Nil) = Channel(Nil).new
    private getter workers : Array(Worker(T)) = Array(Worker(T)).new
    private getter workers_mutex = Mutex.new

    def initialize(@name : String, @total_workers : Int32, @throttle_limit : Int32? = nil)
      create_workers
    end

    def parse_job(job_data : JSON::Any)
      T.from_json job_data.as(String)
    end

    def start
      reprocess_busy_jobs!
      workers.each &.run
    end

    def add(job : String)
      add T.from_json(job)
    end

    def add(job : T)
      store.enqueue job
    rescue ex
      Log.error &.emit("Error Enqueuing", queue: name, error: ex.message)
    end

    def size
      store.queue_size name
    end

    def running?
      workers.all? &.active?
    end

    def running_workers
      workers.count &.active?
    end

    def clear
      store.clear_queue name
    end

    def stop!
      total_workers.times do
        terminate_channel.send(nil)
      end
    end

    def next_job
      # Try to get a job from the store
      store.dequeue(name, T)
    rescue ex
      Log.error &.emit("Error Dequeuing", queue: name, error: ex.message)
    end

    def status
      case {size.zero?, running?}
      when {true, true}  then "Awaiting"
      when {false, true} then "Running"
      else                    "Done"
      end
    end

    def terminate(worker : Worker(T))
      Log.warn &.emit("Terminating Worker", queue: name, worker_id: worker.wid)
      @workers_mutex.synchronize do
        workers.delete worker
      end
    end

    def restart(worker : Worker(T), ex : Exception)
      terminate worker
      return unless running?

      Log.warn &.emit("Restarting Worker!", queue: name, worker_id: worker.wid)
      worker = create_worker
      @workers_mutex.synchronize do
        workers << worker
      end
      worker.run
      worker
    end

    def info
      {
        name:                name,
        total_workers:       total_workers,
        status:              status,
        enqueued:            size,
        completed:           completed.get,
        retried:             retried.get,
        dead:                dead.get,
        processing:          busy.get,
        running_workers:     running_workers,
        jobs_per_second:     jobs_per_second,
        errors_per_second:   errors_per_second,
        enqueued_per_second: enqueued_per_second,
        jobs_latency:        jobs_latency,
        elapsed_time:        Time.monotonic - start_time,
      }
    end

    def jobs_per_second
      elapsed_time = Time.monotonic - @start_time
      return 0.0 if status == "Awaiting" || elapsed_time == 0
      (completed.get.to_f / elapsed_time.to_f)
    end

    def errors_per_second
      elapsed_time = Time.monotonic - @start_time
      return 0.0 if status == "Awaiting" || elapsed_time == 0
      (retried.get.to_f / elapsed_time.to_f)
    end

    def enqueued_per_second
      elapsed_time = Time.monotonic - @start_time
      return 0.0 if status == "Awaiting" || elapsed_time == 0
      (size.to_f / elapsed_time.to_f)
    end

    def jobs_latency
      elapsed_time = Time.monotonic - @start_time
      return 0 if status == "Awaiting" || completed.get == 0
      elapsed_time / completed.get
    end

    private def reprocess_busy_jobs!
      @store.move_job_back_to_queue(name)
    end

    private def create_workers
      total_workers.times do
        workers << create_worker
      end
    end

    private def create_worker
      Worker(T).new workers.size, terminate_channel, self
    end
  end
end
