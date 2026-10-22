require "./spec_helper"

module JoobQ
  describe "Queue pause and lifecycle events" do
    it "reports paused state through the store and clears it on resume" do
      queue = JoobQ.queues["example"]

      queue.paused?.should be_false
      queue.pause!
      queue.paused?.should be_true
      JoobQ.store.as(RedisStore).paused?("example").should be_true
      queue.resume!
      queue.paused?.should be_false
    end

    it "does not process jobs while paused, then drains after resume" do
      queue = Queue(ExampleJob).new("example", 2)
      queue.pause!
      JoobQ.add ExampleJob.new(1)
      queue.start
      eventually { queue.running_workers == 2 }.should be_true
      sleep 300.milliseconds # several worker loop iterations

      queue.size.should eq(1)

      queue.resume!
      deadline = Time.instant + 3.seconds
      while queue.size > 0 && Time.instant < deadline
        sleep 50.milliseconds
      end
      queue.size.should eq(0)
      queue.stop!
    end

    it "emits the job lifecycle in order" do
      sink = CollectingSink.new
      Events.subscribe(sink)
      begin
        queue = Queue(ExampleJob).new("example", 1)
        JoobQ.add ExampleJob.new(7)
        queue.start

        types = [] of String
        3.times { types << JoobQ.receive_event(sink).type }
        types.should eq(["job.enqueued", "job.started", "job.completed"])
        queue.stop!
      ensure
        Events.unsubscribe(sink)
      end
    end

    it "emits job.failed and then job.retrying for a failing job through the real pipeline" do
      sink = CollectingSink.new
      Events.subscribe(sink)
      begin
        queue = Queue(FailJob).new("failed", 1)
        JoobQ.add FailJob.new
        queue.start

        types = [] of String
        6.times do
          types << JoobQ.receive_event(sink).type
          break if types.includes?("job.retrying") || types.includes?("job.dead")
        end
        types.should contain("job.failed")
        (types.includes?("job.retrying") || types.includes?("job.dead")).should be_true
        queue.stop!
      ensure
        Events.unsubscribe(sink)
      end
    end
  end

  describe CachedFlag do
    it "keeps the last value when the source fails" do
      healthy = true
      flag = CachedFlag.new(0.seconds) { healthy ? true : raise("redis down") }

      flag.get.should be_true
      healthy = false
      flag.get.should be_true
    end

    it "serves the cached value within the ttl and sees local changes at once" do
      loads = 0
      flag = CachedFlag.new(1.hour) { loads += 1; false }

      flag.get
      flag.get
      loads.should eq(1)
      flag.set(true)
      flag.get.should be_true
    end

    it "lets a local change win over a load that was already in flight" do
      started = Channel(Nil).new
      release = Channel(Nil).new
      flag = CachedFlag.new(0.seconds) do
        started.send(nil)
        release.receive
        false # stale answer from before the local change
      end

      reader = Channel(Bool).new
      spawn { reader.send(flag.get) }
      started.receive
      flag.set(true)
      release.send(nil)

      reader.receive.should be_true
    end
  end
end
