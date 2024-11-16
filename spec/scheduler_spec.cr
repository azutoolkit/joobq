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
        JoobQ.store.clear_queue "joobq:delayed_jobs"
        JoobQ.store.clear_queue job.queue

        scheduler.delay job, for: 2.seconds
        JoobQ.store.set_size("joobq:delayed_jobs").should eq 1

        scheduler.enqueue 10.seconds.from_now
        JoobQ.store.set_size("joobq:delayed_jobs").should eq 0
      end
    end

    describe "#cron" do
      it "schedules a new recurring job" do
        scheduler.cron("*/1 * * * *") { }
      end

      it "runs recurring jobs" do
        x = 0
        scheduler.cron "* * * * * *" { x = job.perform }

        sleep 2.5.seconds

        x.should be >= 2
        x.should be <= 3
      end
    end
  end
end
