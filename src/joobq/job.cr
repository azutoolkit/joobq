module JoobQ
  module Job
    macro included
      include JSON::Serializable
      
      def self.perform
        job = new
        JoobQ[job.queue].push job.to_json
        job.jid
      end

      def self.perform(**args)
        job = new(**args)
        JoobQ[job.queue].push job.to_json
        job.jid
      end

      def self.perform(within : Time::Span, **args)
        ts = Time.local + within
        job = new(**args)
        job.at = ts if ts > Time.local
        JoobQ.scheduler.delay(job, within)
        job.jid
      end
    end

    # The Unique identifier for this job
    getter jid : UUID = UUID.random
    property queue : String = "default"
    property retries : Int32 = 0
    property at : Time? = nil
    property failed_at : Time? = nil
    property done_at : Time? = nil

    abstract def perform
  end
end
