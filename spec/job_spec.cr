require "./spec_helper"

module JoobQ
  describe Job do
    queue = JoobQ["example"]

    it "performs jobs at later time" do
      job_id = ExampleJob.perform(within: 1.hour, x: 1)
      job_id.should be_a UUID

      REDIS.zcard(Sets::Delayed.to_s).should eq 1
    end
  end
end
