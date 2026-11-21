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

class SchedulerOrphanJob
  include JoobQ::Job

  def initialize
    @queue = "no_such_queue_for_schedules"
  end

  def perform
  end
end

# A struct job: building it and setting its queue must not work on a copy.
struct SchedulerStructJob
  include JoobQ::Job

  getter n : Int32 = 0

  def initialize(@n : Int32 = 0)
    @queue = "yaml_struct_queue"
  end

  def perform
  end
end

# Specs only: reach into the part of the library that cannot be driven from outside.
module JoobQ
  def self.spec_yaml_shut_down(value : Bool) : Nil
    @@shut_down.set(value)
  end
end

PROBE_SOURCE      = File.expand_path("fixtures/yaml_schedulers_probe.cr", __DIR__)
YAML_PROBE_BINARY = File.join(Dir.tempdir, "joobq-yaml-schedulers-probe-#{Random::Secure.hex(4)}")
Spec.after_suite { File.delete?(YAML_PROBE_BINARY) }

# Runs the probe (a `forge` that shuts itself down after a few seconds) and returns its stdout and exit status.
def run_yaml_probe(mode : String) : {String, Process::Status}
  unless File.exists?(YAML_PROBE_BINARY)
    output = IO::Memory.new
    status = Process.run("crystal", ["build", "--no-debug", PROBE_SOURCE, "-o", YAML_PROBE_BINARY], output: output, error: output)
    raise "probe did not build:\n#{output}" unless status.success?
  end
  output = IO::Memory.new
  status = Process.run(YAML_PROBE_BINARY, env: {"PROBE_MODE" => mode, "JOOBQ_ENV" => "test"}, output: output, error: Process::Redirect::Close)
  # The probe's own queue leaves no keys behind in the spec Redis.
  redis = JoobQ.store.as(JoobQ::RedisStore).redis
  redis.keys("*yaml_probe_queue*").each { |key| redis.del(key.to_s) }
  redis.keys("joobq:v1:stats:*").each { |key| redis.hdel(key.to_s, "yaml_probe_queue") rescue nil }
  redis.keys("joobq:v1:schedule:*").each { |key| redis.del(key.to_s) }
  {output.to_s, status}
end

# The probe's COUNT line, or a readable failure with everything it printed.
def probe_counts(output : String) : {Int32, Int32}
  match = output.match(/COUNT before=(\d+) after=(\d+)/) || fail("the probe printed no COUNT line:\n#{output}")
  {match[1].to_i, match[2].to_i}
end

describe "YAML schedulers: firing" do
  config_from = ->(body : String) do
    JoobQ::YamlConfigLoader.load_from_string("joobq:\n  schedulers:\n    - timezone: \"UTC\"\n#{body}")
  end

  cron_yaml = "      cron_jobs:\n        - pattern: \"0 3 * * *\"\n          job: \"ExampleJob\"\n          args: { x: 7 }\n"
  recurring_yaml = "      recurring_jobs:\n        - interval: \"1 hour\"\n          job: \"ExampleJob\"\n          args: { x: 5 }\n"
  no_args = {} of String => YAML::Any
  example_args = {"x" => YAML::Any.new(1_i64)}
  redis = -> { JoobQ.store.as(JoobQ::RedisStore).redis }

  before_each do
    # Another spec may have cleared the registry.
    JoobQ::QueueFactory.register_job_type(ExampleJob)
    JoobQ::QueueFactory.register_job_type(FailJob)
    JoobQ::QueueFactory.register_job_type(SchedulerOrphanJob)
    JoobQ::QueueFactory.register_job_type(SchedulerStructJob)
    JoobQ.config.queues["yaml_struct_queue"] = JoobQ::Queue(SchedulerStructJob).new("yaml_struct_queue", 1)
    JoobQ.store.clear_queue("example")
    JoobQ.store.clear_queue("failed")
    JoobQ.store.clear_queue("yaml_struct_queue")
    redis.call.keys("joobq:v1:schedule:*").each { |key| redis.call.del(key.to_s) }
  end

  after_each do
    JoobQ.config.queues.delete("yaml_struct_queue")
    JoobQ.store.clear_queue("example")
    JoobQ.store.clear_queue("failed")
    JoobQ.store.clear_queue("yaml_struct_queue")
  end

  it "fires by default" do
    JoobQ::Configure.new.fire_yaml_schedulers?.should be_true
  end

  it "enqueues a recurring entry's job on its queue at once" do
    schedules = JoobQ::YamlSchedules.new(config_from.call(recurring_yaml))
    started = schedules.start
    begin
      started.size.should eq(1)
      started.first.recurring_scheduler.jobs.values.map(&.job).should eq(["ExampleJob"])
      eventually { JoobQ.store.queue_size("example") == 1 }.should be_true
    ensure
      schedules.stop
    end
  end

  it "registers a cron entry with its pattern and zone" do
    schedules = JoobQ::YamlSchedules.new(config_from.call(cron_yaml))
    begin
      cron = schedules.start.first.cron_scheduler.jobs.values.first
      cron.pattern.should eq("0 3 * * *")
      cron.timezone.name.should eq("UTC")
    ensure
      schedules.stop
    end
  end

  it "runs the cron loop and enqueues when it is due" do
    # A six-field pattern (every second) is not accepted from YAML; the loop takes it as the DSL's does.
    config = config_from.call(cron_yaml)
    config.scheduler_configs.clear
    config.scheduler_configs << {timezone: "UTC", cron_jobs: [{pattern: "* * * * * *", job: "ExampleJob", args: example_args}], recurring_jobs: [] of NamedTuple(interval: Time::Span, job: String, args: Hash(String, YAML::Any))}
    schedules = JoobQ::YamlSchedules.new(config)
    schedules.start
    begin
      eventually(4.seconds) { JoobQ.store.queue_size("example") >= 1 }.should be_true
    ensure
      schedules.stop
    end
  end

  it "builds the job from the entry's arguments" do
    schedules = JoobQ::YamlSchedules.new(config_from.call(cron_yaml))
    entry = schedules.config.scheduler_configs.first[:cron_jobs].first

    schedules.enqueue(entry[:job], entry[:args])

    JoobQ.store.queue_size("example").should eq(1)
    ExampleJob.from_json(JoobQ.store.list_jobs("example").first).x.should eq(7)
  end

  it "enqueues onto the queue that serves a class job, not the default queue" do
    JoobQ::YamlSchedules.new(config_from.call(cron_yaml)).enqueue("FailJob", no_args)

    JoobQ.store.queue_size("failed").should eq(1)
    JoobQ.store.queue_size("example").should eq(0)
  end

  it "enqueues a struct job onto the queue that serves it" do
    JoobQ::YamlSchedules.new(config_from.call(cron_yaml)).enqueue("SchedulerStructJob", {"n" => YAML::Any.new(4_i64)})

    JoobQ.store.queue_size("yaml_struct_queue").should eq(1)
    JoobQ.store.queue_size("example").should eq(0)
    stored = JSON.parse(JoobQ.store.list_jobs("yaml_struct_queue").first)
    stored["queue"].as_s.should eq("yaml_struct_queue")
    stored["n"].as_i.should eq(4)
  end

  describe "when several queues serve the job" do
    before_each { JoobQ.config.queues["yaml_struct_queue_b"] = JoobQ::Queue(SchedulerStructJob).new("yaml_struct_queue_b", 1) }

    after_each do
      JoobQ.config.queues.delete("yaml_struct_queue_b")
      JoobQ.store.clear_queue("yaml_struct_queue_b")
    end

    it "is refused unless args name the queue" do
      schedules = JoobQ::YamlSchedules.new(config_from.call(cron_yaml))

      expect_raises(JoobQ::ConfigValidationError, /several queues.*args/) { schedules.enqueue("SchedulerStructJob", no_args) }

      schedules.enqueue("SchedulerStructJob", {"queue" => YAML::Any.new("yaml_struct_queue_b")})
      JoobQ.store.queue_size("yaml_struct_queue_b").should eq(1)
    end
  end

  describe "with several processes" do
    it "enqueues one job per entry and tick, whichever instance gets there first" do
      config = config_from.call(cron_yaml)
      first = JoobQ::YamlSchedules.new(config)
      second = JoobQ::YamlSchedules.new(config)

      first.enqueue_tick("spec-entry", 42_i64, 5.seconds, "ExampleJob", example_args).should_not be_nil
      second.enqueue_tick("spec-entry", 42_i64, 5.seconds, "ExampleJob", example_args).should be_nil
      JoobQ.store.queue_size("example").should eq(1)

      second.enqueue_tick("spec-entry", 43_i64, 5.seconds, "ExampleJob", example_args).should_not be_nil
      JoobQ.store.queue_size("example").should eq(2)
    end

    it "claims a recurring entry for one process at a time" do
      config = config_from.call(cron_yaml)
      first = JoobQ::YamlSchedules.new(config)
      second = JoobQ::YamlSchedules.new(config)
      key = JoobQ::Keys.schedule_claim("spec-every")

      first.enqueue_every("spec-every", 1.hour, "ExampleJob", example_args).should_not be_nil
      second.enqueue_every("spec-every", 1.hour, "ExampleJob", example_args).should be_nil
      first.enqueue_every("spec-every", 1.hour, "ExampleJob", example_args).should_not be_nil # its own live claim
      JoobQ.store.queue_size("example").should eq(2)
      ttl = redis.call.pttl(key).as(Int) # one claim per entry, not per window
      ttl.should be > 0
      ttl.should be <= 3_595_000

      redis.call.pexpire(key, 1)
      eventually { redis.call.exists(key) == 0 }.should be_true
      second.enqueue_every("spec-every", 1.hour, "ExampleJob", example_args).should_not be_nil
      first.enqueue_every("spec-every", 1.hour, "ExampleJob", example_args).should be_nil
      JoobQ.store.queue_size("example").should eq(3)
    end

    it "gives back only its own claim" do
      config = config_from.call(cron_yaml)
      first = JoobQ::YamlSchedules.new(config)
      second = JoobQ::YamlSchedules.new(config)
      key = JoobQ::Keys.schedule_tick("spec-owner", 1_i64)

      first.claim(key, 1.minute).should be_true
      second.claim(key, 1.minute).should be_false
      second.release(key) # not the holder: the claim stays
      redis.call.exists(key).should eq(1)
      first.release(key)
      redis.call.exists(key).should eq(0)

      second.claim(key, 1.minute).should be_true
      first.release(key) # the claim expired and another process took it: it stays
      redis.call.exists(key).should eq(1)
    end

    it "keeps a recurring claim a little shorter than the interval" do
      schedules = JoobQ::YamlSchedules.new(config_from.call(cron_yaml))

      schedules.claim_ttl(1.second).should eq(900.milliseconds)
      schedules.claim_ttl(10.seconds).should eq(9.seconds)
      schedules.claim_ttl(1.hour).should eq(1.hour - 5.seconds)
    end

    it "gives a claim back when the enqueue fails, so another process can take the run" do
      schedules = JoobQ::YamlSchedules.new(config_from.call(cron_yaml))

      schedules.enqueue_tick("spec-fail", 1_i64, 1.minute, "SchedulerOrphanJob", no_args).should be_nil
      redis.call.exists(JoobQ::Keys.schedule_tick("spec-fail", 1_i64)).should eq(0)
      schedules.enqueue_every("spec-fail", 1.minute, "SchedulerOrphanJob", no_args).should be_nil
      redis.call.exists(JoobQ::Keys.schedule_claim("spec-fail")).should eq(0)
    end

    it "gives the claim a lifetime" do
      JoobQ::YamlSchedules.new(config_from.call(cron_yaml)).enqueue_tick("spec-entry", 7_i64, 5.seconds, "ExampleJob", example_args)

      ttl = redis.call.pttl(JoobQ::Keys.schedule_tick("spec-entry", 7_i64)).as(Int)
      ttl.should be > 0
      ttl.should be <= 5000
    end

    it "keeps two recurring entries of one job apart" do
      yaml = recurring_yaml + "        - interval: \"2 hours\"\n          job: \"ExampleJob\"\n          args: { x: 6 }\n" \
                              "        - interval: \"2 hours\"\n          job: \"ExampleJob\"\n          args: { x: 9 }\n"
      schedules = JoobQ::YamlSchedules.new(config_from.call(yaml))
      begin
        schedules.start.first.recurring_scheduler.jobs.size.should eq(3)
      ensure
        schedules.stop
      end
    end
  end

  describe "start and stop" do
    it "starts one set however often it is called, and again after stop" do
      schedules = JoobQ::YamlSchedules.new(config_from.call(cron_yaml))
      begin
        first = schedules.start
        schedules.start.first.should be(first.first)
        schedules.stop
        schedules.start.first.should_not be(first.first)
      ensure
        schedules.stop
      end
    end

    it "returns nothing, not the running set, once shutdown has run" do
      schedules = JoobQ::YamlSchedules.new(config_from.call(recurring_yaml))
      schedules.start.should_not be_empty
      JoobQ.spec_yaml_shut_down(true)
      begin
        schedules.start.should be_empty
      ensure
        JoobQ.spec_yaml_shut_down(false)
        schedules.stop
      end
    end

    it "starts nothing once shutdown has run" do
      schedules = JoobQ::YamlSchedules.new(config_from.call(recurring_yaml))
      JoobQ.spec_yaml_shut_down(true)
      begin
        schedules.start.should be_empty
      ensure
        JoobQ.spec_yaml_shut_down(false)
        schedules.stop
      end
    end

    it "builds its set once, whoever asks first" do
      config = JoobQ::Configure.new

      channel = Channel(JoobQ::YamlSchedules).new
      8.times { spawn { channel.send(config.yaml_schedules) } }
      sets = Array.new(8) { channel.receive }

      sets.uniq!(&.object_id).size.should eq(1)
    end

    it "starts nothing when a later group has a bad time zone" do
      config = config_from.call(cron_yaml)
      config.scheduler_configs << {timezone: "Nowhere/Nothing", cron_jobs: [] of NamedTuple(pattern: String, job: String, args: Hash(String, YAML::Any)), recurring_jobs: [] of NamedTuple(interval: Time::Span, job: String, args: Hash(String, YAML::Any))}
      schedules = JoobQ::YamlSchedules.new(config)

      expect_raises(JoobQ::ConfigValidationError, "Nowhere/Nothing") { schedules.start }
      schedules.stop # nothing to stop
    end
  end

  describe "when it is off" do
    it "fires nothing and does not validate the entries" do
      config = config_from.call(recurring_yaml + "        - interval: \"1 hour\"\n          job: \"NoSuchJob\"\n")
      config.fire_yaml_schedulers = false
      schedules = JoobQ::YamlSchedules.new(config)

      schedules.validate!
      schedules.start.should be_empty
      JoobQ.store.queue_size("example").should eq(0)
    end

    it "is set by YAML settings, which must be a boolean" do
      yaml = "joobq:\n  settings:\n    fire_yaml_schedulers: false\n"
      JoobQ::YamlConfigLoader.load_from_string(yaml).fire_yaml_schedulers?.should be_false
      expect_raises(JoobQ::ConfigValidationError, "fire_yaml_schedulers must be true or false") do
        JoobQ::ConfigValidator.validate(YAML.parse("joobq:\n  settings:\n    fire_yaml_schedulers: maybe\n"))
      end
    end

    it "is set by JOOBQ_FIRE_YAML_SCHEDULERS on the configuration the process runs, not only through the env overrides" do
      previous = ENV["JOOBQ_FIRE_YAML_SCHEDULERS"]?
      begin
        {"false" => false, "0" => false, "No" => false, "OFF" => false, "true" => true, "1" => true, "yes" => true, "On" => true}.each do |text, expected|
          ENV["JOOBQ_FIRE_YAML_SCHEDULERS"] = text
          JoobQ.config.fire_yaml_schedulers?.should eq(expected)
        end
        ENV["JOOBQ_FIRE_YAML_SCHEDULERS"] = "flase"
        expect_raises(JoobQ::ConfigValidationError, "JOOBQ_FIRE_YAML_SCHEDULERS") { JoobQ.config.fire_yaml_schedulers? }
        expect_raises(JoobQ::ConfigValidationError, "JOOBQ_FIRE_YAML_SCHEDULERS") { JoobQ::YamlSchedules.new(JoobQ.config).validate! }
      ensure
        previous ? (ENV["JOOBQ_FIRE_YAML_SCHEDULERS"] = previous) : ENV.delete("JOOBQ_FIRE_YAML_SCHEDULERS")
      end
    end

    it "counts an empty or blank JOOBQ_FIRE_YAML_SCHEDULERS as unset" do
      previous = ENV["JOOBQ_FIRE_YAML_SCHEDULERS"]?
      begin
        config = JoobQ::Configure.new
        ["", "   ", "\t"].each do |text|
          ENV["JOOBQ_FIRE_YAML_SCHEDULERS"] = text
          config.fire_yaml_schedulers?.should be_true
        end
        config.fire_yaml_schedulers = false
        ENV["JOOBQ_FIRE_YAML_SCHEDULERS"] = ""
        config.fire_yaml_schedulers?.should be_false
      ensure
        previous ? (ENV["JOOBQ_FIRE_YAML_SCHEDULERS"] = previous) : ENV.delete("JOOBQ_FIRE_YAML_SCHEDULERS")
      end
    end

    it "merges sources without reading or keeping the environment's value" do
      previous = ENV["JOOBQ_FIRE_YAML_SCHEDULERS"]?
      files = ["joobq:\n  settings:\n    fire_yaml_schedulers: true\n", "joobq:\n  settings:\n    retries: 3\n"].map do |yaml|
        File.tempfile("joobq-fire", ".yml", &.print(yaml))
      end
      begin
        ["flase", "false"].each do |env_value| # a typo must not fail the load, and a valid value must not be baked in
          ENV["JOOBQ_FIRE_YAML_SCHEDULERS"] = env_value
          merged = JoobQ::YamlConfigLoader.load_from_sources(files.map(&.path))

          ENV.delete("JOOBQ_FIRE_YAML_SCHEDULERS")
          merged.fire_yaml_schedulers?.should be_true
        end
      ensure
        previous ? (ENV["JOOBQ_FIRE_YAML_SCHEDULERS"] = previous) : ENV.delete("JOOBQ_FIRE_YAML_SCHEDULERS")
        files.each(&.delete)
      end
    end

    it "keeps a source's false through a merge" do
      files = ["joobq:\n  settings:\n    fire_yaml_schedulers: false\n", "joobq:\n  settings:\n    retries: 2\n"].map do |yaml|
        File.tempfile("joobq-fire", ".yml", &.print(yaml))
      end
      begin
        JoobQ::YamlConfigLoader.load_from_sources(files.map(&.path)).fire_yaml_schedulers?.should be_false
      ensure
        files.each(&.delete)
      end
    end
  end

  describe "refuses an entry" do
    it "whose job is not registered" do
      config = config_from.call(recurring_yaml.sub("ExampleJob", "NoSuchJob"))

      expect_raises(JoobQ::ConfigValidationError, "NoSuchJob") { JoobQ::YamlSchedules.new(config).validate! }
    end

    it "whose job no configured queue serves" do
      config = config_from.call(cron_yaml.sub("ExampleJob", "SchedulerOrphanJob"))

      expect_raises(JoobQ::ConfigValidationError, "no configured queue") { JoobQ::YamlSchedules.new(config).validate! }
    end

    it "whose args name a queue that does not serve the job, even when one queue does" do
      schedules = JoobQ::YamlSchedules.new(config_from.call(cron_yaml))

      expect_raises(JoobQ::ConfigValidationError, "'other_queue'") { schedules.enqueue("SchedulerStructJob", {"queue" => YAML::Any.new("other_queue")}) }
      schedules.enqueue("SchedulerStructJob", {"queue" => YAML::Any.new("yaml_struct_queue")})
      JoobQ.store.queue_size("yaml_struct_queue").should eq(1)
    end

    it "whose arguments the job cannot be built from" do
      config = config_from.call(cron_yaml.sub("{ x: 7 }", "{ x: \"seven\" }"))

      expect_raises(JoobQ::ConfigValidationError, "ExampleJob") { JoobQ::YamlSchedules.new(config).validate! }
    end

    it "whose interval is under a second" do
      ["0 seconds", "500 milliseconds"].each do |interval|
        config = config_from.call(recurring_yaml.sub("1 hour", interval))

        expect_raises(JoobQ::ConfigValidationError, "at least 1 second") { JoobQ::YamlSchedules.new(config).validate! }
      end
    end

    it "whose time zone is unknown" do
      config = config_from.call(cron_yaml)
      config.scheduler_configs.clear
      config.scheduler_configs << {timezone: "Nowhere/Nothing", cron_jobs: [{pattern: "0 3 * * *", job: "ExampleJob", args: example_args}], recurring_jobs: [] of NamedTuple(interval: Time::Span, job: String, args: Hash(String, YAML::Any))}

      expect_raises(JoobQ::ConfigValidationError, "Nowhere/Nothing") { JoobQ::YamlSchedules.new(config).validate! }
    end

    it "whose cron pattern cron_parser cannot read" do
      config = config_from.call(cron_yaml)
      config.scheduler_configs.first[:cron_jobs].clear
      config.scheduler_configs.first[:cron_jobs] << {pattern: "not a pattern", job: "ExampleJob", args: example_args}

      expect_raises(JoobQ::ConfigValidationError, "not a pattern") { JoobQ::YamlSchedules.new(config).validate! }
    end
  end

  it "accepts valid entries" do
    JoobQ::YamlSchedules.new(config_from.call(cron_yaml + recurring_yaml)).validate!
  end

  it "gives a group without a timezone the configuration's time zone" do
    yaml = "joobq:\n  settings:\n    timezone: \"Europe/Paris\"\n  schedulers:\n    - recurring_jobs:\n        - interval: \"1 hour\"\n          job: \"ExampleJob\"\n"

    JoobQ::YamlConfigLoader.load_from_string(yaml).scheduler_configs.first[:timezone].should eq("Europe/Paris")
  end

  it "keeps the entries of every source when sources are merged" do
    files = ["joobq:\n  schedulers:\n    - timezone: \"UTC\"\n#{cron_yaml}", "joobq:\n  schedulers:\n    - timezone: \"UTC\"\n#{recurring_yaml}"].map do |yaml|
      File.tempfile("joobq-sched", ".yml", &.print(yaml))
    end
    begin
      merged = JoobQ::YamlConfigLoader.load_from_sources(files.map(&.path))

      merged.scheduler_configs.size.should eq(2)
      merged.scheduler_configs.sum(&.[:cron_jobs].size).should eq(1)
      merged.scheduler_configs.sum(&.[:recurring_jobs].size).should eq(1)
    ensure
      files.each(&.delete)
    end
  end

  describe "JoobQ.forge" do
    it "fires an entry, stops it at shutdown, and does not start anything for a bad entry" do
      output, status = run_yaml_probe("on")
      status.success?.should be_true
      output.should contain("PERFORMED")
      before, after = probe_counts(output)
      before.should be >= 1
      after.should eq(before)

      output, status = run_yaml_probe("bad")
      status.success?.should be_false
      output.should_not contain("PERFORMED")
      output.should contain("NoSuchJob")
    end

    it "fires and validates nothing with the flag off" do
      output, status = run_yaml_probe("off")

      status.success?.should be_true
      output.should_not contain("PERFORMED")
      probe_counts(output).should eq({0, 0})
    end
  end
end
