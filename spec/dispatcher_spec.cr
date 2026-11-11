require "./spec_helper"

# The per-queue dispatcher: one blocking BLMOVE connection per active queue feeds the worker fibers over a channel,
# so idle workers never poll Redis, pick-up is immediate, and Redis connections do not grow with the worker count.
# Claiming still lands in this process's own processing list, so FIFO order and crash recovery are unchanged.
module JoobQ
  class DispatchJob
    include JoobQ::Job
    RAN   = Channel(String).new(1024)
    QUEUE = "dispatch_spec"
    getter label : String

    def initialize(@label : String = "")
      @queue = QUEUE
    end

    def perform
      RAN.send(@label)
    end
  end

  def self.connected_clients(redis) : Int32
    redis.command(["INFO", "clients"]).as(String).match(/connected_clients:(\d+)/).not_nil![1].to_i
  end

  def self.drain(channel, timeout : Time::Span) : Array(String)
    seen = [] of String
    loop do
      select
      when v = channel.receive?
        seen << v if v
      when timeout(timeout)
        return seen
      end
    end
  end

  describe "per-queue dispatcher" do
    store = JoobQ.store.as(RedisStore)
    redis = store.redis
    owned = "joobq:processing:#{DispatchJob::QUEUE}:#{store.owner_id}"

    before_each do
      redis.del(DispatchJob::QUEUE, owned)
      loop do
        select
        when DispatchJob::RAN.receive?
        else
          break
        end
      end
    end

    it "runs jobs in FIFO order with a single worker" do
      queue = Queue(DispatchJob).new(DispatchJob::QUEUE, 1)
      begin
        JoobQ.config.worker_batch_size = 1
        %w[A B C].each { |l| queue.add(DispatchJob.new(l).to_json) }
        queue.start
        ran = JoobQ.drain(DispatchJob::RAN, 5.seconds)
        ran.should eq(%w[A B C])
        queue.dispatching?.should be_true
      ensure
        JoobQ.config.worker_batch_size = 10
        queue.stop!
      end
    end

    # Pick-up latency over several pushes, judged by the median. One sample cannot tell a scheduler or GC stall on a
    # busy machine (tens of milliseconds, once) from a poll; the median can: a 100ms poll spreads latencies evenly
    # over 0..100ms (median ~50ms), the blocking dispatcher sits near 1ms and one stall does not move its median.
    it "picks up a job pushed onto an idle queue in well under the old 100ms poll" do
      queue = Queue(DispatchJob).new(DispatchJob::QUEUE, 2)
      begin
        queue.start
        sleep 300.milliseconds # let the dispatcher settle into its blocking BLMOVE
        latencies = Array(Time::Span).new(9) do |index|
          sleep (20 + Random.rand(100)).milliseconds # no fixed rhythm a poll could fall in step with
          started = Time.instant
          queue.add(DispatchJob.new("now-#{index}").to_json)
          select
          when label = DispatchJob::RAN.receive
            label.should eq("now-#{index}")
          when timeout(2.seconds)
            fail "job #{index} was not picked up within 2 seconds"
          end
          Time.instant - started
        end
        median = latencies.sort[latencies.size // 2]
        fail "median pick-up #{median.total_milliseconds.round(1)}ms is not under 25ms; samples (ms): " \
             "#{latencies.map(&.total_milliseconds.round(1))}" unless median < 25.milliseconds
      ensure
        queue.stop!
      end
    end

    it "does not poll Redis while idle: claim commands stay flat with no jobs" do
      queue = Queue(DispatchJob).new(DispatchJob::QUEUE, 8)
      begin
        queue.start
        sleep 500.milliseconds
        calls = ->(cmd : String) do
          raw = redis.command(["INFO", "commandstats"]).as(String)
          (m = raw.match(/cmdstat_#{cmd}:calls=(\d+)/)) ? m[1].to_i : 0
        end
        before = calls.call("lmove") + calls.call("blmove")
        sleep 2.seconds
        after = calls.call("lmove") + calls.call("blmove")
        # 8 workers polling at 100ms would be ~160 LMOVEs in 2s; the dispatcher issues at most a few BLMOVE blocks.
        (after - before).should be < 12
      ensure
        queue.stop!
      end
    end

    it "keeps Redis connections at rest to about one per queue, not one per worker" do
      base = JoobQ.connected_clients(redis)
      q1 = Queue(DispatchJob).new(DispatchJob::QUEUE, 32)
      begin
        q1.start
        sleep 500.milliseconds
        # 32 workers, but the dispatcher adds only its one dedicated blocking connection (plus pool churn for the
        # heartbeat). Far below the old "one pooled connection per active worker".
        (JoobQ.connected_clients(redis) - base).should be < 8
      ensure
        q1.stop!
      end
    end

    it "reacts to stop within the block timeout even while the dispatcher is blocked on an empty queue" do
      queue = Queue(DispatchJob).new(DispatchJob::QUEUE, 4)
      queue.start
      sleep 300.milliseconds # dispatcher is now parked in BLMOVE on an empty queue
      started = Time.instant
      queue.stop!
      (Time.instant - started).should be < 2.seconds
      queue.dispatching?.should be_false
    end

    it "handles a batch under load in FIFO order" do
      queue = Queue(DispatchJob).new(DispatchJob::QUEUE, 1)
      begin
        JoobQ.config.worker_batch_size = 1
        labels = (0...50).map { |i| "j#{i}" }
        labels.each { |l| queue.add(DispatchJob.new(l).to_json) }
        queue.start
        ran = JoobQ.drain(DispatchJob::RAN, 10.seconds)
        ran.should eq(labels)
      ensure
        JoobQ.config.worker_batch_size = 10
        queue.stop!
      end
    end
  end
end
