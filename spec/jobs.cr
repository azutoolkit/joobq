require "./spec_helper"

class TestJob
  include JoobQ::Job

  getter x
  @queue = "example"

  def initialize(@x : Int32 = 0)
  end

  def perform
    @x += 1
  end
end

module JoobQ
  describe Job do
    it "performs jobs at later time" do
      job_id = ExampleJob.delay(for: 1.hour, x: 1)
      job_id.should be_a UUID

      JoobQ.store.set_size("joobq:delayed_jobs").should eq 1
    end

    it "performs jobs every one second" do
      JoobQ.store.reset
      job = TestJob.schedule(every: 1.second, x: 1)
      sleep 2.seconds
      job.x.should eq 3
    end
  end
end
