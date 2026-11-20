require "./spec_helper"

describe "time zone settings" do
  it "applies the zone to the configuration without changing the process zone" do
    process_zone = Time::Location.local
    config = JoobQ::Configure.new
    config.time_location = "UTC"

    config.time_location.name.should eq("UTC")
    Time::Location.local.should be(process_zone)
  end

  it "accepts a Time::Location" do
    config = JoobQ::Configure.new
    config.time_location = Time::Location.load("Asia/Tokyo")
    config.time_location.name.should eq("Asia/Tokyo")
  end

  it "reaches a YAML-configured Scheduler's default and leaves the process zone alone" do
    process_zone = Time::Location.local
    config = JoobQ::YamlConfigLoader.load_from_string(<<-YAML)
      joobq:
        settings:
          timezone: "Europe/Berlin"
    YAML
    config.time_location.name.should eq("Europe/Berlin")
    Time::Location.local.should be(process_zone)

    previous = JoobQ.config
    begin
      JoobQ.set_config(config)
      scheduler = JoobQ::Scheduler.new
      scheduler.cron("0 9 * * *") { }
      scheduler.jobs.keys.should eq(["0 9 * * *:Europe/Berlin"])
    ensure
      JoobQ.set_config(previous)
    end
  end

  it "keeps the zone of the last source when sources are merged" do
    base = File.tempfile("base", ".yml", &.print("joobq:\n  settings:\n    timezone: \"Asia/Tokyo\"\n"))
    over = File.tempfile("over", ".yml", &.print("joobq:\n  settings:\n    retries: 5\n"))
    begin
      JoobQ::YamlConfigLoader.load_from_sources([base.path]).time_location.name.should eq("Asia/Tokyo")
      JoobQ::YamlConfigLoader.load_from_sources([base.path, over.path]).time_location.name.should eq("Asia/Tokyo")
      JoobQ::YamlConfigLoader.load_from_sources([over.path, base.path]).time_location.name.should eq("Asia/Tokyo")
    ensure
      base.delete
      over.delete
    end
  end
end
