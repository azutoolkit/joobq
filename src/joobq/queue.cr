module JoobQ
  abstract class BaseQueue
    abstract def push(job : String)
  end

  class Queue(T) < BaseQueue
    private TIMEOUT = 2

    getter store : Store = JoobQ.config.store
    getter name : String
    getter total_workers : Int32
    getter workers : Array(Worker(T))
    getter jobs : String = T.to_s
    getter terminate_channel = Channel(Nil).new
    property completed : Atomic(Int64) = Atomic.new(0_i64)
    property retried : Atomic(Int64) = Atomic.new(0_i64)
    property dead : Atomic(Int64) = Atomic.new(0_i64)
    property busy : Atomic(Int64) = Atomic.new(0_i64)
    property start_time : Time::Span = Time.monotonic

    def initialize(@name : String, @total_workers : Int32)
      @workers = Array(Worker(T)).new(@total_workers)
      reprocess_busy_jobs!
      create_workers
    end

    def parse_job(job_data : JSON::Any)
      T.from_json job_data.as(String)
    end

    def start
      workers.each &.run
    end

    def push(job : String)
      push T.from_json(job)
    end

    def push(job : T)
      Log.info &.emit("Enqueing", queue: name, job_id: job.jid.to_s)
      store.push job
    rescue ex
      Log.error &.emit("Error Enqueuing", queue: name, error: ex.message)
    end

    def size
      store.length name
    end

    def running?
      workers.all? &.active?
    end

    def running_workers
      workers.count &.active?
    end

    def clear
      store.del name
    end

    def stop!
      total_workers.times do
        terminate_channel.send(nil)
      end
    end

    def next : T?
      store.get(name, T)
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
      workers.delete worker
    end

    def restart(worker : Worker(T), ex : Exception)
      terminate worker
      return unless running?

      Log.warn &.emit("Restarting Worker!", queue: name, worker_id: worker.wid)
      worker = create_worker
      workers << worker
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
      }
    end

    def jobs_per_second
      elapsed_time = Time.monotonic - @start_time
      return 0.0 if elapsed_time == 0
      (@completed.get.to_f / elapsed_time.to_f)
    end

    def errors_per_second
      elapsed_time = Time.monotonic - @start_time
      return 0.0 if elapsed_time == 0
      (@retried.get.to_f / elapsed_time.to_f)
    end

    def enqueued_per_second
      elapsed_time = Time.monotonic - @start_time
      return 0.0 if elapsed_time == 0
      (size.to_f / elapsed_time.to_f)
    end

    def jobs_latency
      elapsed_time = Time.monotonic - @start_time
      return 0 if completed.get == 0
      elapsed_time / completed.get
    end

    private def reprocess_busy_jobs!
      spawn do
        loop do
          item = @store.put_back(name)
          next unless item
          sleep 3.seconds unless status == "Awaiting"
        end
      end
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
