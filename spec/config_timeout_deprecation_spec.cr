require "./spec_helper"

# `config.timeout` is kept for JoobQ Pro's `Job#with_timeout`; Core never enforces it, so setting it says so, once.
describe "config.timeout deprecation" do
  yaml_with = "joobq:\n  settings:\n    timeout: \"30 seconds\"\n"
  yaml_without = "joobq:\n  settings:\n    retries: 4\n"

  # The deprecation notices `block` logs, from a fresh once-per-process flag.
  warnings = ->(block : ->) do
    logs = Log::MemoryBackend.new
    Log.builder.bind("*", :warn, logs)
    JoobQ::Configure.reset_timeout_warning!
    begin
      block.call
    ensure
      Log.builder.unbind("*", :warn, logs)
    end
    logs.entries.select(&.message.includes?("config.timeout is deprecated"))
  end

  # Runs `block` with a YAML file holding `yaml` on disk.
  with_file = ->(yaml : String, block : String ->) do
    file = File.tempfile("joobq-timeout", ".yml", &.print(yaml))
    begin
      block.call(file.path)
    ensure
      file.delete
    end
  end

  it "warns once when YAML sets it, however many files and settings set it" do
    found = warnings.call(-> {
      JoobQ::YamlConfigLoader.load_from_string(yaml_with)
      JoobQ::YamlConfigLoader.load_from_string(yaml_with)
      JoobQ::Configure.new.timeout = 5.seconds
    })

    found.size.should eq(1)
    found.first.message.should contain("not enforce")
    found.first.message.should contain("with_timeout")
    found.first.message.should contain("docs/reference/configuration.md")
  end

  it "warns when the configure DSL sets it" do
    warnings.call(-> { JoobQ::Configure.new.timeout = 5.seconds }).size.should eq(1)
  end

  it "warns when JOOBQ_TIMEOUT sets it" do
    with_file.call(yaml_without, ->(path : String) do
      previous = ENV["JOOBQ_TIMEOUT"]?
      begin
        ENV["JOOBQ_TIMEOUT"] = "45 seconds"
        config = nil
        found = warnings.call(-> { config = JoobQ::YamlConfigLoader.load_with_env_overrides(path) })

        found.size.should eq(1)
        config.not_nil!.timeout.should eq(45.seconds)
      ensure
        previous ? (ENV["JOOBQ_TIMEOUT"] = previous) : ENV.delete("JOOBQ_TIMEOUT")
      end
    end)
  end

  it "stays quiet when nothing sets it, merged configurations included" do
    found = warnings.call(-> {
      JoobQ::YamlConfigLoader.load_from_string(yaml_without)
      JoobQ::Configure.new.timeout
      with_file.call(yaml_without, ->(path : String) { JoobQ::YamlConfigLoader.load_from_sources([path, path]) })
    })

    found.should be_empty
  end

  # Merges the YAML sources (one file each) and gives back the result with the notices logged.
  merged = ->(sources : Array(String)) do
    config = nil
    found = warnings.call(-> do
      files = sources.map { |yaml| File.tempfile("joobq-timeout", ".yml", &.print(yaml)) }
      begin
        config = JoobQ::YamlConfigLoader.load_from_sources(files.map(&.path))
      ensure
        files.each(&.delete)
      end
    end)
    {config.not_nil!, found}
  end

  it "keeps a source's timeout through a merge, with one warning" do
    config, found = merged.call([yaml_with])

    config.timeout.should eq(30.seconds)
    found.size.should eq(1)
  end

  it "keeps the earlier source's timeout when a later source sets none" do
    config, _ = merged.call([yaml_with, yaml_without])

    config.timeout.should eq(30.seconds)
  end

  it "takes the later source's timeout when both set one" do
    config, found = merged.call([yaml_with, "joobq:\n  settings:\n    timeout: \"90 seconds\"\n"])

    config.timeout.should eq(90.seconds)
    found.size.should eq(1)
  end

  it "leaves the default when no source sets one" do
    config, found = merged.call([yaml_without, yaml_without])

    config.timeout.should eq(2.seconds)
    config.timeout_set?.should be_false
    found.should be_empty
  end

  it "keeps the value readable for JoobQ Pro" do
    config = nil
    warnings.call(-> { config = JoobQ::YamlConfigLoader.load_from_string(yaml_with) })

    config.not_nil!.timeout.should eq(30.seconds)
    config.not_nil!.timeout_set?.should be_true
    JoobQ::Configure.new.timeout_set?.should be_false
    JoobQ::Configure.new.timeout.should eq(2.seconds)
  end

  # Each shipped file loads whole; production sets `timeout` (for Pro), so it is the one that logs the notice.
  Dir.glob(File.expand_path("../config/joobq.*.yml", __DIR__)).sort.each do |path|
    name = File.basename(path)
    expected = name == "joobq.production.yml" ? 1 : 0

    it "#{name} loads and logs the deprecation notice #{expected} time(s)" do
      found = warnings.call(-> { JoobQ::YamlConfigLoader.load_from_file(path) })

      found.size.should eq(expected)
    end
  end
end
