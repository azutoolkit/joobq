require "./spec_helper"

# Registered only by the example that checks a late registration.
class RegistryLateJob
  include JoobQ::Job

  def initialize
    @queue = "registry_late"
  end

  def perform
  end
end

# One registry of queues per process: `Configure#queues` is the store, `JoobQ.queues` and `QueueFactory.queues` return
# that very Hash. Queues here are built but never started.
module JoobQ
  describe "the queue registry" do
    config = JoobQ.config
    redis = JoobQ.store.as(RedisStore).redis
    names = [] of String
    fresh = -> { "registry_#{Random::Secure.hex(4)}".tap { |n| names << n } }

    before_each do
      QueueFactory.register_job_type(ExampleJob)
    end

    after_each do
      names.each do |name|
        JoobQ.queues.delete(name)
        config.queues.delete(name)
        config.queue_configs.delete(name)
        redis.keys("joobq:*#{name}*").each { |key| redis.del(key.to_s) }
      end
      names.clear
    end

    it "is one Hash: JoobQ.queues is JoobQ.config.queues" do
      JoobQ.queues.same?(config.queues).should be_true
    end

    it "shows a queue put in JoobQ.queues to JoobQ.config.queues" do
      name = fresh.call
      queue = Queue(ExampleJob).new(name, 1)
      JoobQ.queues[name] = queue
      config.queues[name]?.should be(queue)
    end

    it "shows a queue put in JoobQ.config.queues to JoobQ.queues" do
      name = fresh.call
      queue = Queue(ExampleJob).new(name, 1)
      JoobQ.queues # read first: a memoised copy would already exist
      config.queues[name] = queue
      JoobQ.queues[name]?.should be(queue)
    end

    it "creates a YAML-configured queue once, into the registry" do
      name = fresh.call
      config.queue_configs[name] = {job_class_name: "ExampleJob", workers: 2, throttle: nil}
      created = JoobQ.queues[name]
      created.total_workers.should eq(2)
      config.queues[name]?.should be(created)
      JoobQ.queues[name].should be(created)
      QueueFactory.queues[name].should be(created)
    end

    it "keeps the typed queue when a YAML entry has the same name" do
      name = fresh.call
      typed = Queue(ExampleJob).new(name, 3)
      config.queues[name] = typed
      config.queue_configs[name] = {job_class_name: "ExampleJob", workers: 9, throttle: nil}
      JoobQ.queues[name].should be(typed)
      config.queues[name].should be(typed)
      typed.total_workers.should eq(3)
    end

    it "tries a YAML entry it cannot create once, until its job type is registered" do
      name = fresh.call
      config.queue_configs[name] = {job_class_name: "RegistryLateJob", workers: 1, throttle: nil}
      logs = Log::MemoryBackend.new
      Log.builder.bind("*", :error, logs)
      begin
        3.times { JoobQ.queues.has_key?(name).should be_false }
      ensure
        Log.builder.unbind("*", :error, logs)
      end
      logs.entries.count(&.message.includes?("Failed to create queue '#{name}'")).should eq(1)
      QueueFactory.register_job_type(RegistryLateJob)
      JoobQ.queues[name].job_type.should eq("RegistryLateJob")
    end

    it "survives clear_queues_cache: a registered queue stays the same instance" do
      name = fresh.call
      queue = Queue(ExampleJob).new(name, 1)
      config.queues[name] = queue
      QueueFactory.clear_queues_cache
      JoobQ.queues[name].should be(queue)
      config.queues[name].should be(queue)
    end
  end
end
