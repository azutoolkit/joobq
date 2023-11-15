module JoobQ
  class JobQueue(T)
    getter name : String = "default"
    getter heap : Array(T) = [] of T
    getter mutex : Mutex = Mutex.new
    getter terminate : Channel(Nil) = Channel(Nil).new
    getter file_path : String = "./default.json"

    def initialize
      load_from_file
      write_to_file_periodically
    end

    # Spawn a new fiber
    def process
      spawn do
        loop do
          select
          when terminate.receive?
            break
          else
            if job = dequeue
              next if job.status == "processed"
              job.perform
              job.status = "processed"
              Log.info { "Processed job: #{job.jid} Priority: #{job.priority}" }
            else
              sleep 0.1
            end
          end
        end
      end
    end

    def size
      heap.size
    end

    # Insert job in the correct position
    def enqueue(job : T)
      mutex.synchronize do
        index = heap.bsearch_index { |j| j <= job } || heap.size
        heap.insert(index, job)
      end
    end

    # Remove the highest-priority job
    def dequeue : T?
      mutex.synchronize do
        heap.shift? unless heap.empty?
      end
    end

    private def write_to_file_periodically
      spawn do
        loop do
          write_to_file
          sleep 5.seconds
        end
      end
    end

    private def write_to_file
      mutex.synchronize do
        # Filter out processed jobs before writing to file
        unprocessed_jobs = heap.reject { |j| j.status == "processed" }
        File.write(file_path, unprocessed_jobs.to_json)
        Log.info { "Wrote #{unprocessed_jobs.size} jobs to file" }
      end
    rescue e
      puts "Error writing to file: #{e.message}"
      # Handle or log the error appropriately
    end

    private def load_from_file
      mutex.synchronize do
        if File.exists?(file_path)
          heap = Array(T).from_json(File.read(file_path))
          Log.info { "Read #{heap.size} jobs from file" }
        end
      end
    rescue e
      puts "Error loading from file: #{e.message}"
      # Handle or log the error appropriately
    end
  end
end
