require "./spec_helper"

module JoobQ
  # Counts its runs; the queue name travels in the payload (`queue` is overridden by `add!`).
  class OutsideJob
    include JoobQ::Job

    RAN = Atomic(Int32).new(0)

    def initialize(queue : String = "outside_unused")
      @queue = queue
    end

    def perform
      RAN.add(1)
    end
  end

  # What the joobq-pro workflow engine does: put a hand-built Queue into the registry from outside the YAML/DSL path.
  describe "a queue registered from outside the DSL" do
    store = JoobQ.store.as(RedisStore)
    redis = store.redis
    name = ""
    started = [] of Queue(OutsideJob)

    before_each do
      name = "outside_#{Random::Secure.hex(4)}"
      OutsideJob::RAN.set(0)
    end

    after_each do
      started.each(&.stop!)
      started.clear
      JoobQ.queues.delete(name)
      redis.del(name, "joobq:processing:#{name}:#{store.owner_id}", "joobq:worker:outside-host:1")
      redis.zrem(WorkerRegistry::INDEX, "outside-host:1")
    end

    it "is accepted by JoobQ.enqueue, found by JoobQ[], listed and counted" do
      queue = Queue(OutsideJob).new(name, 1)
      JoobQ.queues[name] = queue

      jid = JoobQ.enqueue(name, OutsideJob.new(name).to_json)

      redis.llen(name).should eq(1)
      redis.lrange(name, 0, -1).first.to_s.should contain(jid)
      JoobQ[name].should be(queue)
      JoobQ.queues.keys.should contain(name)
      JoobQ.config.queues.has_key?(name).should be_true
      JoobQ.queues.values.count(&.same?(queue)).should eq(1)
    end

    it "runs a job end to end once started" do
      queue = Queue(OutsideJob).new(name, 1)
      JoobQ.queues[name] = queue
      started << queue
      queue.start

      JoobQ.enqueue(name, OutsideJob.new(name).to_json)

      eventually { OutsideJob::RAN.get == 1 && redis.llen(name) == 0 }.should be_true
      eventually { redis.llen("joobq:processing:#{name}:#{store.owner_id}") == 0 }.should be_true
      OutsideJob::RAN.get.should eq(1)
    end

    it "appears in the worker registry's queues and concurrency" do
      queue = Queue(OutsideJob).new(name, 3)
      JoobQ.queues[name] = queue

      WorkerRegistry.new(store, id: "outside-host:1").beat

      info = WorkerRegistry.all.find! { |worker| worker.id == "outside-host:1" }
      info.queues.should contain(name)
      info.concurrency.should be >= 3
    end

    it "replaces the entry of a running name without raising, and the old instance keeps running until stopped" do
      old = Queue(OutsideJob).new(name, 1)
      other = Queue(OutsideJob).new(name, 1)
      JoobQ.queues[name] = old
      started << old
      old.start

      JoobQ.queues[name] = other

      JoobQ[name].should be(other)
      old.running?.should be_true
      old.stop!
      old.running?.should be_false
      JoobQ[name].should be(other)
      JoobQ.queues.values.count(&.same?(other)).should eq(1)
    end
  end
end
