require "./spec_helper"

describe "YAML schedulers:" do
  yaml = <<-YAML
    joobq:
      schedulers:
        - timezone: "UTC"
          cron_jobs:
            - pattern: "* * * * *"
              job: "ExampleJob"
              args: { x: 1 }
          recurring_jobs:
            - interval: "1 second"
              job: "ExampleJob"
              args: { x: 2 }
  YAML

  it "is parsed into scheduler_configs for a host to read" do
    config = JoobQ::YamlConfigLoader.load_from_string(yaml)

    entry = config.scheduler_configs.first
    entry[:timezone].should eq("UTC")
    entry[:cron_jobs].first[:pattern].should eq("* * * * *")
    entry[:cron_jobs].first[:job].should eq("ExampleJob")
    entry[:recurring_jobs].first[:job].should eq("ExampleJob")
  end

  it "is never fired by Core: nothing is registered or enqueued" do
    JoobQ.reset
    registered_before = JoobQ.config.schedulers.sum { |s| s.jobs.size }
    config = JoobQ::YamlConfigLoader.load_from_string(yaml)

    sleep 1.5.seconds

    config.schedulers.should be_empty
    JoobQ.config.schedulers.sum { |s| s.jobs.size }.should eq(registered_before)
    JoobQ.store.as(JoobQ::RedisStore).queue_size("example").should eq(0)
  end

  it "has no method that pretends to set them up" do
    JoobQ::Configure.new.responds_to?(:setup_schedulers_from_config).should be_false
  end
end
