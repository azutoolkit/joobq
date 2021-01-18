module JoobQ
  class Queue(T)
    private TIMEOUT = 2

    getter redis : Redis::PooledClient = JoobQ::REDIS
    getter name : String
    getter total_workers : Int32
    getter workers : Array(Worker(T))
    getter jobs : String = T.to_s
    getter terminate_channel = Channel(Nil).new

    def initialize(@name : String, @total_workers : Int32)
      @workers = Array(Worker(T)).new(@total_workers)
      create_workers
    end

    def start
      workers.each &.run
    end

    def push(job : String)
      JoobQ.push T.from_json(job)
    end

    def push(job : T)
      JoobQ.push job
    end

    def size
      redis.llen(name)
    end

    def running?
      workers.all? &.active?
    end

    def running_workers
      workers.count &.active?
    end

    def clear
      redis.del name
    end

    def stop!
      total_workers.times do |_n|
        terminate_channel.send nil
      end
    end

    def get_next : T?
      # Add to BUSY queue so we can later monitor busy jobs and be able to
      # gracefully terminate jobs in flight
      if job_id = redis.brpoplpush(name, Status::Busy.to_s, TIMEOUT)
        return self.get_job(job_id)
      end
    rescue ex
      nil
    end

    def get_job(job_id : String | UUID) : T?
      if job_data = redis.get("jobs:#{job_id}")
        return T.from_json job_data.as(String)
      end
    rescue ex
      nil
    end

    def status
      case {size.zero?, running?}
      when {true, true}  then "Awaiting"
      when {false, true} then "Running"
      else                    "Done"
      end
    end

    def terminate(worker : Worker(T))
      Log.warn &.emit("Terminating Worker!", Queue: name, Worker_Id: worker.wid)
      workers.delete worker
    end

    def restart(worker : Worker(T), ex : Exception)
      terminate worker
      return unless running?

      Log.warn &.emit("Restarting Worker!", Queue: name, Worker_Id: worker.wid)
      worker = create_worker
      workers << worker
      worker.run
      worker
    end

    private def create_workers
      total_workers.times do |_n|
        workers << create_worker
      end
    end

    private def create_worker
      Worker(T).new workers.size, terminate_channel, self
    end
  end
end
