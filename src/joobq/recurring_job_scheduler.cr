module JoobQ
  class RecurringJobScheduler
    getter jobs : Hash(String, Time::Span)

    def self.instance
      @@instance ||= new
    end

    def initialize
      @jobs = {} of String => Time::Span
    end

    def every(interval : Time::Span, job : Job.class, **args)
      job_instance = job.new(**args)
      job_key = job_instance.class.name
      @jobs[job_key] = interval

      spawn do
        loop do
          start_time = Time.monotonic
          spawn { job_instance.perform }
          sleep interval
        end
      end

      job_instance
    end
  end
end
