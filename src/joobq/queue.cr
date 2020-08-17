module JoobQ
  class Queue(T)
    getter redis : Redis::PooledClient = JoobQ.redis
    getter name : String
    getter total_workers : Int32
    getter workers : Array(Worker(T))
    getter jobs : String = T.to_s
    
    @channel : Channel(T)
    @done = Channel(Control).new

    def initialize(@name : String, @total_workers : Int32)
      @channel = Channel(T).new(@total_workers)
      @workers = Array(Worker(T)).new(@total_workers)
      create_workers
    end

    def create_workers
      total_workers.times do |n|
        @workers << Worker(T).new @name, n, @channel, @done
      end
    end

    def process
      return if running?
      @workers.each &.run
      spawn do
        while running?
          redis.pipelined do |pipe|
            total_workers.times do |_i|
              pipe.rpoplpush @name, Queues::Busy.to_s
            end
          end.each_with_index do |job, i|
            next unless job
            work = T.from_json(job.as(String))
            @channel.send(work)
            done = @done.receive
          end
        end
      end
    end

    def running?
      @workers.all? &.running?
    end

    def status
      case
      when !running? && size > 0   then "Running"
      when !running? && size.zero? then "Done"
      else                              "Awaiting"
      end
    end

    def push(job : String)
      redis.lpush name, job
    end

    def running_workers
      @workers.count &.running?
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
