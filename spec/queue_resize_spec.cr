require "./spec_helper"

module JoobQ
  describe "Queue#resize" do
    it "grows and shrinks the running workers" do
      queue = Queue(ExampleJob).new("example", 2)
      queue.start
      eventually { queue.running_workers == 2 }.should be_true

      queue.resize(5)
      eventually { queue.running_workers == 5 }.should be_true
      queue.total_workers.should eq(5)

      queue.resize(1)
      eventually { queue.running_workers == 1 }.should be_true
      queue.stop!
    end

    it "rejects a non-positive size" do
      expect_raises(ArgumentError) { Queue(ExampleJob).new("example", 1).resize(0) }
    end

    it "persists the desired size and announces it" do
      sink = CollectingSink.new
      Events.subscribe(sink)
      begin
        Queue(ExampleJob).new("example", 1).resize(3)

        JoobQ.store.as(RedisStore).desired_concurrency("example").try(&.[:count]).should eq(3)
        JoobQ.receive_event(sink).type.should eq("queue.resized")
      ensure
        Events.unsubscribe(sink)
      end
    end

    it "is followed by the registry when set after the process started" do
      queue = JoobQ.queues["example"]
      original = queue.total_workers
      registry = WorkerRegistry.new
      sleep 5.milliseconds
      JoobQ.store.as(RedisStore).set_concurrency("example", original + 2)

      registry.follow_desired_concurrency

      queue.total_workers.should eq(original + 2)
    ensure
      queue.try(&.apply_concurrency(original.not_nil!)) if original
      JoobQ.store.as(RedisStore).redis.del("joobq:queue:example:config")
    end

    it "ignores a size that was set before the process started" do
      queue = JoobQ.queues["example"]
      original = queue.total_workers
      JoobQ.store.as(RedisStore).set_concurrency("example", original + 2)
      sleep 5.milliseconds

      WorkerRegistry.new.follow_desired_concurrency

      queue.total_workers.should eq(original)
    ensure
      JoobQ.store.as(RedisStore).redis.del("joobq:queue:example:config")
    end
  end
end
