module JoobQ

  class Queue(T)
    getter redis : Redis::PooledClient = JoobQ.redis
    getter name : String
    getter total_workers : Int32
    getter workers : Array(Worker(T))
    getter jobs : String = T.to_s
    getter job_queue : Channel(Array(String))
    getter queue_size : Int32 = 100

    def initialize(@name : String, @total_workers : Int32,  @queue_size = 100)
      @job_queue = Channel(Array(String)).new(@queue_size)
      @dispatch_queue = Channel(Worker(T)).new(@total_workers)
      @workers = Array(Worker(T)).new(@total_workers)
      create_workers
    end

    def create_workers
      total_workers.times do |n|
        workers << Worker(T).new name, n, job_queue
      end
    end

    def process
      return false if running?
      workers.each &.run

      spawn do
        while running?
          result = redis.pipelined do |pipe|
            queue_size.times do |_i|
              pipe.brpoplpush name, "#{Queues::Busy.to_s}:#{name}", 0
            end
          end.map { |j| j.as(String) }

          job_queue.send result
        end
      end
    end

    def stop!
      workers.all? &.stop
    end

    def running?
      workers.all? &.running?
    end

    def status
      case
      when !size.zero? then "Running"
      when size.zero? then "Done"
      else "Awaiting"
      end
    end

    def push(job : String)
      redis.lpush name, job
    end

    def running_workers
      workers.count &.running?
    end

    def clear
      redis.del name
    end

    def size
      redis.llen(name)
    rescue e
      0
    end
  end
end
