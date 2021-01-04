module JoobQ
  module Job
    macro included
      include JSON::Serializable

      # The Unique identifier for this job
      getter jid : UUID = UUID.random
      property queue : String = "default"
      property retries : Int32 = 0
      property expires : Int32 = 3.days.total_seconds.to_i

      def self.perform
        JoobQ.push new
      end

      def self.perform(**args)
        JoobQ.push new(**args)
      end

      def self.perform(within : Time::Span, **args)
        ts = Time.local + within
        job = new(**args)
        job.at = ts if ts > Time.local
        JoobQ.scheduler.delay(job, within)
        job.jid
      end
    end

    abstract def perform
  end
end
