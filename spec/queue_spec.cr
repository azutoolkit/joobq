require "./spec_helper"

module JoobQ
  describe Queue do
    job = ExampleJob.new 1
    total_jobs = 100
    queue = JoobQ["example"]

    before_each do
      redis.del "example"
      JoobQ.reset
      queue.clear
    end

    describe "#process" do
      it "runs a job" do
        total_jobs.times do |i|
          queue.push ExampleJob.new(i).to_json
        end

        total_jobs.times do
          job = FailJob.new
          job.queue = "example"
          job.retries = 3
          queue.push job.to_json
        end

        queue.size.should eq (total_jobs * 2)

        start = Time.local
        queue.process
        sleep 3

        queue.size.should eq 0
        redis.llen(Queues::Busy.to_s).should eq 0
        redis.zcard(Sets::Retry.to_s).should eq 100
      end
    end
  end
end
