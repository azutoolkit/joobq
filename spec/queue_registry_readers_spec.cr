require "./spec_helper"

# A queue that exists only as a `queue_configs` YAML entry, or only as `JoobQ.queues[name] = queue` (engine style), must
# be served by the background readers (delayed-job scheduler, reaper) even though nothing called `JoobQ.queues` for it.
module JoobQ
  describe "background readers of the queue registry" do
    config = JoobQ.config
    store = JoobQ.store.as(RedisStore)
    redis = store.redis
    names = [] of String
    fresh = -> { "readers_#{Random::Secure.hex(4)}".tap { |n| names << n } }
    due_job = ->(queue : String) { ExampleJob.new(1).tap { |j| j.queue = queue }.to_json }
    scheduler = DelayedJobScheduler.new(store)

    before_each { QueueFactory.register_job_type(ExampleJob) }

    after_each do
      scheduler.stop
      names.each do |name|
        JoobQ.queues.delete(name)
        config.queues.delete(name)
        config.queue_configs.delete(name)
        redis.zrange(RedisStore::DELAYED_SET, 0, -1).each do |raw|
          redis.zrem(RedisStore::DELAYED_SET, raw.to_s) if raw.to_s.includes?(name)
        end
        redis.keys("joobq:*#{name}*").each { |key| redis.del(key.to_s) }
        redis.del(name)
      end
      redis.zrem(RedisStore::OWNERS, "host:dead")
      names.clear
    end

    it "promotes a due delayed job of a YAML-only queue" do
      name = fresh.call
      config.queue_configs[name] = {job_class_name: "ExampleJob", workers: 1, throttle: nil}
      config.queues.has_key?(name).should be_false # never touched through JoobQ.queues
      store.schedule_job(due_job.call(name), 0_i64)

      scheduler.start
      eventually { store.queue_size(name) == 1 }.should be_true
    end

    it "promotes a due delayed job of a queue registered only with JoobQ.queues[name] =" do
      name = fresh.call
      JoobQ.queues[name] = Queue(ExampleJob).new(name, 1)
      store.schedule_job(due_job.call(name), 0_i64)

      scheduler.start
      eventually { store.queue_size(name) == 1 }.should be_true
    end

    it "recovers an orphaned processing list of a YAML-only queue in one reaper pass" do
      name = fresh.call
      config.queue_configs[name] = {job_class_name: "ExampleJob", workers: 1, throttle: nil}
      redis.lpush("joobq:processing:#{name}:host:dead", due_job.call(name))
      redis.zrem(RedisStore::OWNERS, "host:dead")

      ExpiredJobReaper.new(store: store).reap_once
      store.queue_size(name).should eq(1)
    end
  end
end
