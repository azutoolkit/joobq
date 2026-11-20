require "./spec_helper"

# The members docs/reference/public-api.md lists as frozen. `Job` stands for a class that includes JoobQ::Job.
# The page is read at compile time: a row whose first cell is `Receiver.member` or `Receiver#member` becomes an example.
{% for line in read_file("#{__DIR__}/../docs/reference/public-api.md").lines %}
  {% if line.starts_with?("| `") %}
    {% cell = line.split("`")[1] %}
    {% unless cell.includes?(" ") %}
      {% instance = cell.includes?("#") %}
      {% parts = instance ? cell.split("#") : cell.split(".") %}
      {% receiver = parts[0] == "Job" ? "ExampleJob" : parts[0] %}
      {% type = parse_type(receiver).resolve %}
      {% type = type.class unless instance %}
      describe "public API row {{cell.id}}" do
        it "exists" do
          {{ type.has_method?(parts[1]) }}.should be_true
        end
      end
    {% end %}
  {% end %}
{% end %}

# True when `type` has class methods called `name` and every one carries @[Deprecated]. `name` is a literal.
macro deprecated_class_methods?(type, name)
  {% methods = type.resolve.class.methods.select { |m| m.name.stringify == name } %}
  {{ !methods.empty? && methods.all? { |m| m.annotation(Deprecated) } }}
end

# Runs the block the way `JoobQ.configure` does, against a configuration of its own.
def configure_fresh(&)
  config = JoobQ::Configure.new
  with config yield config
  config
end

describe "the public surface of JoobQ" do
  before_each do
    JoobQ.reset
  end

  describe "the Job module" do
    it "enqueues, delays, batches and performs" do
      ExampleJob.enqueue(x: 1).should be_a(String)
      ExampleJob.delay(for: 1.hour, x: 1).should be_a(UUID)
      ExampleJob.batch_enqueue([ExampleJob.new(1), ExampleJob.new(2)])
      ExampleJob.perform(x: 1)
      JoobQ["example"].size.should eq 3
      job = ExampleJob.new(1)
      {job.jid, job.queue, job.retries, job.max_retries, job.expires, job.status, job.error, job.past_expiration?}.size.should eq 8
      JoobQ::Job::Status.values.map(&.to_s).should eq %w(Completed Dead Enqueued Expired Retrying Running Scheduled)
    end
  end

  describe "the JoobQ module" do
    it "enqueues a job instance and raw JSON" do
      JoobQ.enqueue(ExampleJob.new(7)).should be_a(String)
      JoobQ.enqueue("example", ExampleJob.new(8).to_json).should be_a(String)
      expect_raises(JoobQ::UnknownQueue) { JoobQ.enqueue("nope", "{}") }
      JoobQ["example"].size.should eq 2
    end

    it "gives access to the registry, the store and the monitor" do
      JoobQ.queues.has_key?("example").should be_true
      JoobQ["example"].should be_a(JoobQ::BaseQueue)
      JoobQ.store.should be_a(JoobQ::Store)
      JoobQ.error_monitor.should be_a(JoobQ::ErrorMonitor)
      JoobQ.config.should be_a(JoobQ::Configure)
      JoobQ.abandoned_jobs.should be_a(Int32)
      {JoobQ::EXIT_CLEAN, JoobQ::EXIT_ABANDONED}.should eq({0, 3})
    end

    it "builds and installs a configuration" do
      previous = JoobQ.config
      begin
        config = JoobQ::Configure.new
        JoobQ.set_config(config)
        JoobQ.config.should be(config)
        JoobQ.configure { |c| c.default_queue = "other" }
        config.default_queue.should eq "other"
      ensure
        JoobQ.set_config(previous)
      end
    end

    it "keeps JoobQ.scheduler out: it called a Scheduler.instance that never existed" do
      {{ JoobQ.class.has_method?("scheduler") }}.should be_false
    end
  end

  describe "the Configure DSL" do
    it "declares queues and registers job classes inside a configuration block" do
      config = configure_fresh do
        queue "surface", 2, ExampleJob
        register_job ExampleJob
        scheduler { }
        error_monitoring(time_window: 1.hour)
      end
      config.queues["surface"].should be_a(JoobQ::BaseQueue)
      config.schedulers.size.should eq 1
    end
  end

  # Calling a deprecated member prints a compiler warning, and this build stays warning-free, so the annotation is
  # checked instead of a call.
  describe "deprecated members carry @[Deprecated]" do
    it "JoobQ.add, the JoobQ.load_* wrappers and JoobQ.find_config_file" do
      {% for name in %w(add load_from_yaml load_hybrid load_from_yaml_sources load_from_cli_args load_auto load_from_file load_from_string load_with_env_overrides find_config_file) %}
        deprecated_class_methods?(JoobQ, {{name}}).should be_true, "JoobQ.{{name.id}}"
      {% end %}
    end

    it "Job.enqueue_at" do
      deprecated_class_methods?(ExampleJob, "enqueue_at").should be_true
    end
  end
end
