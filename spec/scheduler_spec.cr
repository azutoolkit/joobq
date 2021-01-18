require "./spec_helper"

module JoobQ
  describe Scheduler do
    scheduler = JoobQ.scheduler
    job = ExampleJob.new 2

    before_each do
      JoobQ.reset
    end

    describe "#every" do
      it "executes job at interval" do
        scheduler.every 10.seconds, ExampleJob, x: 2
      end
    end

    describe "#delay" do
      it "delays job to a time in the future" do
        REDIS.del Sets::Delayed.to_s
        REDIS.del job.queue

        scheduler.delay job, 2.seconds
        REDIS.zcard(Sets::Delayed.to_s).should eq 1

        scheduler.enqueue 5.seconds.from_now

        REDIS.zcard(Sets::Delayed.to_s).should eq 0
      end
    end

    describe "#cron" do
      it "registers recurring jobs at specific time" do
        scheduler.register do
          cron("*/1 * * * *") { }
          cron("*/5 20-23 * * *") { }
        end
      end

      it "schedules a new recurring job" do
        scheduler.cron("*/1 * * * *") { }
      end

      it "runs recurring jobs" do
        x = 0
        scheduler.cron "* * * * * *" { x = job.perform }

        sleep 2.5

        x.should be >= 2
        x.should be <= 3
      end
    end
  end
end
