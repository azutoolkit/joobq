require "./spec_helper"

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
      QueueFactory.clear_queues_cache
    end

    after_each do
      names.each do |name|
        JoobQ.queues.delete(name)
        config.queues.delete(name)
        config.queue_configs.delete(name)
        redis.keys("joobq:*#{name}*").each { |key| redis.del(key.to_s) }
      end
      names.clear
      QueueFactory.clear_queues_cache
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
