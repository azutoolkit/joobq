require "./spec_helper"

describe JoobQ do
  it "registers a queue" do
    JoobQ.queues.size.should eq 3
  end

  it "gets queue by name" do
    JoobQ["example"].should be_a JoobQ::Queue(ExampleJob)
    JoobQ["single"].should be_a JoobQ::Queue(Job1)
  end

  it "registers recurring jobs at specific time" do
    jobs = JoobQ.config.schedulers.first.cron_scheduler.jobs

    jobs["*/30 * * * *:America/New_York"].should_not be_nil
    jobs["*/5 20-23 * * *:America/New_York"].should_not be_nil
    # jobs[ExampleJob.name].should_not be_nil
  end
end
