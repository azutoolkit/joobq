module JoobQ
  class RecurringJobScheduler
    getter jobs : Hash(String, Scheduler::RecurringJob)

    def self.instance
      @@instance ||= new
    end

    def initialize
      @jobs = {} of String => Scheduler::RecurringJob
    end

    def every(interval : Time::Span, job : Job.class, **args)
      job_instance = job.new(**args)
      job_key = job_instance.class.name
      @jobs[job_key] = Scheduler::RecurringJob.new(interval: interval, job: job.name, args: args.to_json)

      spawn do
        loop do
          spawn { job_instance.perform }
          sleep interval
        end
      end

      job_instance
    end
  end
end
