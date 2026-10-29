require "./spec_helper"

private def durable_runtime(capacity = 2, lease = 300.milliseconds)
  JoobQ::Delivery::Runtime.new(JoobQ::RedisStore.instance, "runtime-#{UUID.random}", capacity: capacity,
    lease: lease, poll: 5.milliseconds, repair_every: 20.milliseconds)
end

describe JoobQ::Delivery::Runtime do
  it "renews slow handlers while keeping the shared execution budget" do
    runtime = durable_runtime
    entered = Channel(Nil).new(10)
    release = Channel(Nil).new(10)
    ledger = runtime.register("slow") do |raw, context|
      entered.send(nil)
      release.receive
      context.check!
      JoobQ::Delivery::Outcome.new
    end
    6.times { |i| runtime.admit("slow", i.to_s, "payload") }
    runtime.start
    2.times do
      select
      when entered.receive
      when timeout(5.seconds)
        fail "workers did not execute"
      end
    end
    sleep 450.milliseconds
    runtime.active_count.should eq(2)
    ledger.claim("competitor").should_not be_nil # unclaimed work remains available
    runtime.active_count.should eq(2)
    6.times { release.send(nil) }
    eventually { ledger.resolve("0").try(&.state.completed?) }.should be_true
    runtime.stop(2.seconds).clean.should be_true
    runtime.metrics.prometheus.should contain("joobq_delivery_execution_seconds_count")
  ensure
    6.times { release.try(&.send(nil)) } if runtime && runtime.active_count > 0
    runtime.try(&.stop(1.second))
  end

  it "returns a bounded incomplete drain and rejects late settlement" do
    runtime = durable_runtime(1)
    entered = Channel(Nil).new(1)
    release = Channel(Nil).new(1)
    ledger = runtime.register("blocked") do |raw, context|
      entered.send(nil)
      release.receive
      JoobQ::Delivery::Outcome.new
    end
    runtime.admit("blocked", "id", "payload")
    runtime.start
    select
    when entered.receive
    when timeout(5.seconds)
      fail "worker did not execute"
    end
    result = runtime.stop(50.milliseconds)
    result.clean.should be_false
    result.active.should eq(1)
    result.elapsed.should be < 300.milliseconds
    expect_raises(ArgumentError) { runtime.start }
    expect_raises(ArgumentError) { runtime.admit("blocked", "new", "payload") }
    release.send(nil)
    eventually { runtime.active_count == 0 }.should be_true
    ledger.resolve("id").not_nil!.state.should eq(JoobQ::Delivery::State::Leased)
    sleep 350.milliseconds
    ledger.repair
    next_claim = ledger.claim("replacement").not_nil!
    next_claim.attempt.should eq(2)
    ledger.settle(next_claim).should eq(JoobQ::Delivery::Settlement::Applied)
  ensure
    runtime.try(&.stop(1.second))
  end

  it "keeps admissions idempotent when retained-record capacity is full" do
    store = JoobQ::RedisStore.instance
    ledger = JoobQ::Delivery::Ledger.new(store.redis, "capacity", UUID.random.to_s, max_records: 1)
    ledger.admit("one", "payload").code.accepted?.should be_true
    ledger.admit("two", "payload").code.rejected?.should be_true
    ledger.admit("one", "payload").code.accepted?.should be_true
  end
end

class DurableTypedSpecJob
  include JoobQ::Job
  getter message : String
  @@performed = Atomic(Int32).new(0)

  def initialize(@message = "ok")
  end

  def self.performed
    @@performed.get
  end

  def perform
    raise "expected failure" if message == "fail"
    @@performed.add(1)
  end
end

describe "typed durable execution and supervision" do
  it "executes typed jobs and deterministically exhausts retries" do
    runtime = durable_runtime
    ledger = runtime.register("typed", DurableTypedSpecJob)
    before = DurableTypedSpecJob.performed
    good = DurableTypedSpecJob.new
    bad = DurableTypedSpecJob.new("fail")
    bad.max_retries = 0
    runtime.enqueue("typed", good)
    runtime.enqueue("typed", bad)
    runtime.start
    eventually { ledger.resolve(good.jid.to_s).try(&.state.completed?) }.should be_true
    eventually { ledger.resolve(bad.jid.to_s).try(&.state.dead?) }.should be_true
    DurableTypedSpecJob.performed.should eq(before + 1)
  ensure
    runtime.try(&.stop(2.seconds))
  end

  it "cancels overlong execution without releasing its real fiber slot" do
    runtime = JoobQ::Delivery::Runtime.new(JoobQ::RedisStore.instance, "execution-limit-#{UUID.random}",
      capacity: 1, lease: 300.milliseconds, execution_timeout: 100.milliseconds,
      poll: 5.milliseconds, repair_every: 20.milliseconds)
    entered = Channel(JoobQ::Delivery::Context).new(1)
    release = Channel(Nil).new(1)
    ledger = runtime.register("work") do |raw, context|
      entered.send(context)
      release.receive
      JoobQ::Delivery::Outcome.new
    end
    runtime.admit("work", "id", "payload")
    runtime.start
    context = select
    when value = entered.receive
      value
    when timeout(5.seconds)
      raise "handler did not enter"
    end
    sleep 150.milliseconds
    context.cancelled?.should be_true
    runtime.active_count.should eq(1)
    expect_raises(JoobQ::Delivery::LeaseLost) { context.check! }
    runtime.stop(10.milliseconds).clean.should be_false
    release.send(nil)
    eventually { runtime.active_count == 0 }.should be_true
    ledger.resolve("id").not_nil!.state.completed?.should be_false
  ensure
    release.try(&.send(nil)) if runtime && runtime.active_count > 0
    runtime.try(&.stop(2.seconds))
  end

  it "allows one half-open probe and recovers after repeated transport failures" do
    breaker = JoobQ::Delivery::Circuit.new
    5.times { breaker.failure }
    breaker.allow?.should be_false
    sleep 410.milliseconds
    breaker.allow?.should be_true
    breaker.allow?.should be_false
    breaker.success
    3.times { breaker.allow?.should be_true }
  end
end
