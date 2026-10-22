require "./spec_helper"

module JoobQ
  describe BackgroundLoop do
    it "runs iterations until stopped and never runs one after stop returns" do
      bg = BackgroundLoop.new("spec")
      count = Atomic(Int32).new(0)

      bg.start do
        count.add(1)
        1.millisecond
      end.should be_true

      sleep 50.milliseconds
      bg.stop.should be_true

      after_stop = count.get
      after_stop.should be > 0
      sleep 50.milliseconds
      count.get.should eq(after_stop)
      bg.running?.should be_false
    end

    it "waits for an in-flight iteration to finish before stop returns" do
      bg = BackgroundLoop.new("spec")
      entered = Channel(Nil).new(1)
      finished = Atomic(Bool).new(false)

      bg.start do
        entered.send(nil)
        sleep 100.milliseconds
        finished.set(true)
        1.hour
      end

      entered.receive
      bg.stop
      finished.get.should be_true
    end

    it "wakes a long sleep promptly" do
      bg = BackgroundLoop.new("spec")
      started = Channel(Nil).new(1)
      bg.start do
        started.send(nil)
        1.hour
      end

      started.receive
      t0 = Time.instant
      bg.stop
      (Time.instant - t0).should be < 1.second
    end

    it "is idempotent on double start and double stop" do
      bg = BackgroundLoop.new("spec")
      bg.start { 1.hour }.should be_true
      bg.start { 1.hour }.should be_false
      bg.stop.should be_true
      bg.stop.should be_false
    end

    it "can be restarted after stop" do
      bg = BackgroundLoop.new("spec")
      ran = Channel(Nil).new(1)

      bg.start { 1.hour }
      bg.stop
      bg.start do
        ran.send(nil) rescue nil
        1.hour
      end.should be_true

      select
      when ran.receive
      when timeout(2.seconds)
        fail "restarted loop did not run"
      end
      bg.stop
    end

    it "keeps looping after an iteration raises" do
      bg = BackgroundLoop.new("spec")
      calls = Channel(Int32).new(4)
      n = Atomic(Int32).new(0)

      bg.start do
        calls.send(n.add(1) + 1)
        raise "boom" if n.get == 1
        1.hour
      end

      # first iteration raises and backs off ERROR_BACKOFF; only assert it ran
      select
      when calls.receive
      when timeout(2.seconds)
        fail "iteration did not run"
      end
      bg.stop(wait: 1.second)
    end

    it "does not deadlock when stopped from inside its own body" do
      bg = BackgroundLoop.new("spec")
      stopped = Channel(Bool).new(1)

      bg.start do
        stopped.send(bg.stop)
        1.hour
      end

      select
      when result = stopped.receive
        result.should be_true
      when timeout(2.seconds)
        fail "self-stop deadlocked"
      end
    end
  end
end
