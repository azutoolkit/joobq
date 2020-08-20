require "./spec_helper"

module JoobQ
  describe Job do

    before_each do
      JoobQ.reset
    end

    context "one queue for single job type" do
      it "works" do
        queue = "single"

        REDIS.del queue
        REDIS.del Sets::Delayed.to_s
        REDIS.del queue

        Job1.perform

        REDIS.llen(queue).should eq 1
      end
    end

    context "one queue for multiple job types" do
      it "works" do
        queue = "example"

        REDIS.del queue
        REDIS.del Sets::Delayed.to_s
        REDIS.del queue

        ExampleJob.perform(x: 1)
        FailJob.perform

        REDIS.llen(queue).should eq 2
      end

      it "performs and enqueue jobs asyncronously" do
        queue = "example"

        REDIS.del queue
        REDIS.del Sets::Delayed.to_s

        job_id = ExampleJob.perform(x: 1)

        job_id.should be_a UUID
        REDIS.llen(queue).should eq 1
      end

      it "performs jobs at later time" do
        queue = "example"
        REDIS.del queue
        REDIS.del Sets::Delayed.to_s

        job_id = ExampleJob.perform(within: 1.hour, x: 1)
        job_id.should be_a UUID

        REDIS.zcard(Sets::Delayed.to_s).should eq 1
      end
    end
  end
end
