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

  it "registers no scheduler of its own: Core builds none from the section" do
    config = JoobQ::YamlConfigLoader.load_from_string(yaml)

    config.schedulers.should be_empty
  end

  it "has no method that pretends to set them up" do
    JoobQ::Configure.new.responds_to?(:setup_schedulers_from_config).should be_false
  end
end
