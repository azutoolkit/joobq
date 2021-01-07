require "./spec_helper"

module JoobQ
  describe Scheduler do
    scheduler = JoobQ.scheduler
    job = ExampleJob.new 2

    before_each do
      JoobQ.reset
    end

    describe "delayes jobs" do
      it "enqueues and process a job when ready" do
        REDIS.del Sets::Delayed.to_s
        REDIS.del job.queue

        scheduler.delay job, 2.seconds
        REDIS.zcard(Sets::Delayed.to_s).should eq 1

        scheduler.enqueue 5.seconds.from_now

        REDIS.zcard(Sets::Delayed.to_s).should eq 0
      end
    end

    describe "periodic jobs" do
      it "should define jobs" do
        scheduler.register do
          at("*/1 * * * *") { }
          at("*/5 20-23 * * *") { }
        end
      end

      it "custom add job" do
        scheduler.at("*/1 * * * *") { }
      end

      it "run the jobs" do
        x = 0
        scheduler.at("* * * * * *") { x = job.perform }
        sleep 2.5
        x.should be >= 2
        x.should be <= 3
      end

      it "stats" do
        scheduler.at("* * * * * *") { }
        s = scheduler.stats
        x = s.find { |c| c[:name] == "* * * * * *" }.not_nil!
        (x[:sleeping_for].as(Float64)).should be <= 1.0
      end
    end
  end
end
