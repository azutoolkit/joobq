require "./spec_helper"

# Raises on its first call, then counts. Class level state because the
# scheduler owns the instance it builds.
class SchedulerFlakyJob
  include JoobQ::Job

  @@calls = Atomic(Int32).new(0)

  def self.calls : Int32
    @@calls.get
  end

  def self.reset
    @@calls.set(0)
  end

  def initialize
    @queue = "example"
  end

  def perform
    raise ArgumentError.new("boom") if @@calls.add(1) == 0
  end
end

module JoobQ
  describe "scheduler resilience" do
    describe RecurringJobScheduler do
      it "keeps scheduling after a run raises" do
        SchedulerFlakyJob.reset
        scheduler = RecurringJobScheduler.new(error_backoff: 10.milliseconds)
        scheduler.every(20.milliseconds, SchedulerFlakyJob)

        deadline = Time.instant + 3.seconds
        while SchedulerFlakyJob.calls < 3 && Time.instant < deadline
          sleep 10.milliseconds
        end
        scheduler.stop

        # call 1 raised; calls 2 and 3 prove the loop outlived it
        SchedulerFlakyJob.calls.should be >= 3
      end

      it "stops: no run starts after stop returns" do
        SchedulerFlakyJob.reset
        scheduler = RecurringJobScheduler.new
        scheduler.every(10.milliseconds, SchedulerFlakyJob)
        sleep 50.milliseconds
        scheduler.stop

        sleep 20.milliseconds # let an already spawned run finish
        after_stop = SchedulerFlakyJob.calls
        sleep 100.milliseconds
        SchedulerFlakyJob.calls.should eq(after_stop)
      end
    end

    describe CronJobScheduler do
      it "keeps firing after a loop iteration raises" do
        scheduler = CronJobScheduler.new(error_backoff: 10.milliseconds)
        runs = Atomic(Int32).new(0)
        pattern = "* * * * * *" # every second
        scheduler.cron(pattern, Time::Location::UTC) { runs.add(1) }

        key = scheduler.jobs.keys.first
        entry = scheduler.jobs[key]

        # Make the loop's own bookkeeping raise (KeyError) for a while.
        scheduler.jobs.delete(key)
        sleep 100.milliseconds
        scheduler.jobs[key] = entry

        deadline = Time.instant + 5.seconds
        while runs.get < 2 && Time.instant < deadline
          sleep 20.milliseconds
        end
        scheduler.stop

        runs.get.should be >= 2
      end

      it "survives a job block that raises" do
        scheduler = CronJobScheduler.new(error_backoff: 10.milliseconds)
        runs = Atomic(Int32).new(0)
        scheduler.cron("* * * * * *", Time::Location::UTC) do
          runs.add(1)
          raise "cron job failed"
        end

        deadline = Time.instant + 5.seconds
        while runs.get < 2 && Time.instant < deadline
          sleep 20.milliseconds
        end
        scheduler.stop

        runs.get.should be >= 2
      end

      it "stops: no run starts after stop returns" do
        scheduler = CronJobScheduler.new
        runs = Atomic(Int32).new(0)
        scheduler.cron("* * * * * *", Time::Location::UTC) { runs.add(1) }

        deadline = Time.instant + 5.seconds
        while runs.get < 1 && Time.instant < deadline
          sleep 20.milliseconds
        end
        scheduler.stop

        sleep 20.milliseconds
        after_stop = runs.get
        sleep 1500.milliseconds
        runs.get.should eq(after_stop)
      end
    end
  end
end
