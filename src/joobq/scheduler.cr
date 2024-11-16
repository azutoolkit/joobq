module JoobQ
  # ### Overview
  #
  # The `Scheduler` class is responsible for managing job scheduling. It supports scheduling jobs to run at specific
  # intervals, delaying jobs, and running jobs based on cron patterns. The `Scheduler` ensures that jobs are executed
  # at the right time and provides mechanisms for recurring and delayed job execution.
  #
  # ### Properties
  #
  # - `jobs : Hash(String, RecurringJobs | CronParser)` - A hash that stores scheduled jobs and their intervals or cron
  #   patterns.
  # - `store : Store` - The store instance used for job storage and retrieval.
  #
  # ### Methods
  #
  # #### `instance`
  #
  # ```
  # def self.instance
  # ```
  #
  # Returns the singleton instance of the `Scheduler`.
  #
  # #### `clear`
  #
  # ```
  # def clear
  # ```
  #
  # Clears all periodic jobs from the scheduler.
  #
  # #### `delay`
  #
  # ```
  # def delay(job : JoobQ::Job, for till : Time::Span)
  # ```
  #
  # Delays a job to be executed after a specified timespan.
  #
  # #### `every`
  #
  # ```
  # def every(interval : Time::Span, job : JoobQ::Job.class, **args)
  # ```
  #
  # Schedules a job to run at a specified interval.
  #
  # #### `cron`
  #
  # ```
  # def cron(pattern, &block : ->)
  # ```
  #
  # Schedules a job to run based on a cron pattern.
  #
  # ### Usage
  #
  # #### Delaying a Job
  #
  # To delay a job for a specific timespan, use the `delay` method:
  #
  # ```
  # scheduler = JoobQ.scheduler
  # job = ExampleJob.new(x: 1)
  # scheduler.delay(job, for: 2.minutes)
  # ```
  #
  # #### Scheduling a Recurring Job
  #
  # To schedule a job to run at a specific interval, use the `every` method:
  #
  # ```
  # scheduler = JoobQ.scheduler
  # scheduler.every(5.minutes, ExampleJob, x: 1)
  # ```
  #
  # #### Scheduling a Cron Job
  #
  # To schedule a job based on a cron pattern, use the `cron` method:
  #
  # ` ``crystal
  # scheduler = JoobQ.scheduler
  # scheduler.cron("*/5 * * * *") do
  #   ExampleJob.new(x: 1).perform
  # end
  # ```
  #
  # ### Scheduler Workflow
  #
  # 1. **Initialization**:
  #   - The `Scheduler` class is initialized as a singleton instance using the `instance` method.
  #   - The `jobs` hash is used to store scheduled jobs and their intervals or cron patterns.
  #
  # 2. **Delaying Jobs**:
  #   - The `delay` method schedules a job to be executed after a specified timespan.
  #   - The job is added to the store with a delay in milliseconds.
  #
  # 3. **Scheduling Recurring Jobs**:
  #   - The `every` method schedules a job to run at a specified interval.
  #   - A new job instance is created and stored in the `jobs` hash.
  #   - A loop is spawned to execute the job at the specified interval.
  #
  # 4. **Scheduling Cron Jobs**:
  #   - The `cron` method schedules a job based on a cron pattern.
  #   - A `CronParser` instance is created and stored in the `jobs` hash.
  #   - A loop is spawned to execute the job based on the cron pattern.
  #
  # 5. **Job Execution**:
  #   - For recurring jobs, the job is executed at the specified interval.
  #   - For cron jobs, the job is executed based on the cron pattern.
  #   - The `perform` method of the job is called to execute the job logic.
  #
  # ### Example
  #
  # Here is a complete example demonstrating how to use the `Scheduler` class:
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
  # # Get the scheduler instance
  # scheduler = JoobQ.scheduler
  #
  # # Delay a job
  # job = ExampleJob.new(x: 1)
  # scheduler.delay(job, for: 2.minutes)
  #
  # # Schedule a recurring job
  # scheduler.every(5.minutes, ExampleJob, x: 1)
  #
  # # Schedule a cron job
  # scheduler.cron("*/5 * * * *") do
  #   ExampleJob.new(x: 1).perform
  # end
  # ```
  #
  # This example sets up a scheduler, delays a job, schedules a recurring job, and schedules a cron job.
  class Scheduler
    record RecurringJobs, job : Job, queue : String, interval : Time::Span | CronParser

    getter jobs = {} of String => RecurringJobs | CronParser
    private getter store : Store = JoobQ.store

    def self.instance
      @@instance ||= new
    end

    def clear
      @periodic_jobs.clear
    end

    def delay(job : JoobQ::Job, for till : Time::Span)
      store.schedule(job, delay_in_ms: till.from_now.to_unix_ms)
    end

    def every(interval : Time::Span, job : JoobQ::Job.class, **args)
      job_instance = job.new **args
      @jobs[job.name] = RecurringJobs.new job_instance, job_instance.queue, interval

      spawn do
        loop do
          sleep interval
          spawn { job_instance.perform }
        end
      end

      job_instance
    end

    def cron(pattern, &block : ->)
      parser = CronParser.new(pattern)
      @jobs[pattern] = parser
      spawn do
        prev_nxt = Time.monotonic - 1.minute

        loop do
          now = Time.local
          nxt = parser.next(now)
          nxt = parser.next(nxt) if nxt == prev_nxt
          prev_nxt = nxt
          sleep(nxt - now)
          spawn { block.call }
        end
      end
    end

    def run
      spawn do
        loop do
          enqueue
          sleep 3.seconds
        end
      end
    rescue ex : Exception
      Log.error &.emit("Scheduler Crashed", reason: ex.message)
      run
    end

    def enqueue(current_time = Time.local)
      results = store.fetch_due_jobs(current_time)
      results.as(Array).each do |data|
        next unless data.is_a?(String)
        job_json = JSON.parse(data.as(String))
        queue_name = job_json["queue"].as_s
        queue = JoobQ.queues[queue_name]
        queue.add data.as(String)
      end
    end
  end
end
