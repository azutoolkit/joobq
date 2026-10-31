require "./spec_helper"

describe "bounded durable delivery batches" do
  it "retains per-ID conflicts, capacity decisions, and replayable terminal receipts" do
    redis = JoobQ::RedisStore.instance.redis
    ledger = JoobQ::Delivery::Ledger.new(redis, "batch", UUID.random.to_s, max_records: 2)
    results = ledger.admit_many([{"a", "one"}, {"a", "different"}, {"b", "two"}, {"c", "three"}])
    results.map(&.code).should eq([JoobQ::Delivery::AdmissionCode::Accepted, JoobQ::Delivery::AdmissionCode::Rejected,
                                   JoobQ::Delivery::AdmissionCode::Accepted, JoobQ::Delivery::AdmissionCode::Rejected])
    claims = ledger.claim_many("owner", 32)
    claims.size.should eq(2)
    claims.map(&.token).uniq.size.should eq(2)
    items = claims.map { |claim| {claim, JoobQ::Delivery::State::Completed, Time::Span.zero} }
    ledger.settle_many(items).all?(&.applied?).should be_true
    ledger.settle_many(items).all?(&.already_applied?).should be_true
    ledger.resolve_many(["a", "b", "c"]).map { |r| r.try(&.state) }.should eq([
      JoobQ::Delivery::State::Completed, JoobQ::Delivery::State::Completed, nil,
    ])
    ledger.admit_many([{"a", "one"}])[0].code.accepted?.should be_true
  end

  it "fences expired ownership separately for each item and preserves retry delays" do
    ledger = JoobQ::Delivery::Ledger.new(JoobQ::RedisStore.instance.redis, "batch-fence", UUID.random.to_s)
    ledger.admit_many([{"a", "one"}, {"b", "two"}])
    claims = ledger.claim_many("old", 2, 10.milliseconds)
    sleep 20.milliseconds
    ledger.repair
    newer = ledger.claim_many("new", 2)
    ledger.settle_many(claims.map { |c| {c, JoobQ::Delivery::State::Completed, Time::Span.zero} }).all?(&.stale?).should be_true
    ledger.settle_many([{newer[0], JoobQ::Delivery::State::Scheduled, 1.hour},
                        {newer[1], JoobQ::Delivery::State::Dead, Time::Span.zero}]).all?(&.applied?).should be_true
    ledger.claim_many("early", 2).should be_empty
  end

  it "reports unknown partial writes and repairs canonical admission intent" do
    redis = JoobQ::RedisStore.instance.redis
    ledger = JoobQ::Delivery::Ledger.new(redis, "batch-partial", UUID.random.to_s)
    redis.set(ledger.ready_key, "wrong type")
    results = ledger.admit_many([{"a", "one"}, {"b", "two"}])
    results.all?(&.code.unknown?).should be_true
    ledger.resolve("a").should_not be_nil
    ledger.resolve("b").should be_nil
    redis.del(ledger.ready_key)
    ledger.repair
    ledger.admit_many([{"a", "one"}, {"b", "two"}]).all?(&.code.accepted?).should be_true
    ledger.claim_many("worker", 2).size.should eq(2)
  end

  it "preserves exact Int64 metadata and quarantines corrupt original bytes" do
    redis = JoobQ::RedisStore.instance.redis
    ledger = JoobQ::Delivery::Ledger.new(redis, "batch-integrity", UUID.random.to_s)
    receipts = ledger.admit_many([{"a", "one"}, {"b", "two"}])
    entry = receipts[0].entry.not_nil!
    entry.attempt = 9_007_199_254_740_990_i64
    redis.hset(ledger.records_key, entry.id, entry.to_json)
    broken = receipts[1].entry.not_nil!.to_json.sub("two", "bad")
    redis.hset(ledger.records_key, receipts[1].id, broken)
    claims = ledger.claim_many("worker", 2)
    claims.size.should eq(1)
    claims[0].attempt.should eq(9_007_199_254_740_991_i64)
    redis.hget(ledger.quarantine_key, receipts[1].id).should eq(broken)
    ledger.settle_many([{claims[0], JoobQ::Delivery::State::Completed, Time::Span.zero}])[0].applied?.should be_true
  end

  it "bounds count and bytes before admission and honors maintenance during claims" do
    redis = JoobQ::RedisStore.instance.redis
    ledger = JoobQ::Delivery::Ledger.new(redis, "batch-bounds", UUID.random.to_s)
    expect_raises(ArgumentError) { ledger.admit_many(Array.new(129) { |i| {i.to_s, "x"} }) }
    expect_raises(ArgumentError) { ledger.admit_many(Array.new(3) { |i| {i.to_s, "x" * 1_048_576} }) }
    redis.hlen(ledger.records_key).should eq(0)
    ledger.admit_many([{"a", "one"}])
    redis.set(ledger.gate_key, "operator")
    ledger.claim_many("worker", 2).should be_empty
  end

  it "reconciles interrupted batch settlement without replaying completed handlers" do
    redis = JoobQ::RedisStore.instance.redis
    ledger = JoobQ::Delivery::Ledger.new(redis, "batch-settle-partial", UUID.random.to_s)
    ledger.admit_many([{"a", "one"}, {"b", "two"}])
    claims = ledger.claim_many("worker", 2)
    items = claims.map { |c| {c, JoobQ::Delivery::State::Completed, Time::Span.zero} }
    redis.del(ledger.leases_key)
    redis.set(ledger.leases_key, "wrong type")
    ledger.settle_many(items).all?(&.unknown?).should be_true
    redis.del(ledger.leases_key)
    ledger.repair
    results = ledger.settle_many(items)
    results.should eq([JoobQ::Delivery::Settlement::AlreadyApplied, JoobQ::Delivery::Settlement::Applied])
    ledger.resolve_many(["a", "b"]).all? { |r| r.try(&.state.completed?) }.should be_true
  end

  it "reloads batch scripts after eviction without losing item-level results" do
    redis = JoobQ::RedisStore.instance.redis
    ledger = JoobQ::Delivery::Ledger.new(redis, "batch-cache", UUID.random.to_s)
    2.times do |i|
      redis.command(["SCRIPT", "FLUSH"])
      ledger.admit_many([{i.to_s, "payload"}])[0].code.accepted?.should be_true
      claims = ledger.claim_many("worker", 2)
      redis.command(["SCRIPT", "FLUSH"])
      ledger.settle_many(claims.map { |c| {c, JoobQ::Delivery::State::Completed, Time::Span.zero} })[0].applied?.should be_true
    end
  end

  it "rejects replacement payloads even when their replacement checksum is valid" do
    redis = JoobQ::RedisStore.instance.redis
    ledger = JoobQ::Delivery::Ledger.new(redis, "batch-payload-fence", UUID.random.to_s)
    receipt = ledger.admit("a", "original")
    claim = ledger.claim_many("worker", 1)[0]
    changed = JSON.parse(redis.hget(ledger.records_key, receipt.id).not_nil!)
    changed.as_h["payload"] = JSON::Any.new("replacement")
    changed.as_h["digest"] = JSON::Any.new(Digest::SHA256.hexdigest("replacement"))
    redis.hset(ledger.records_key, receipt.id, changed.to_json)
    expect_raises(JoobQ::Delivery::CorruptRecord) do
      ledger.settle_many([{claim, JoobQ::Delivery::State::Completed, Time::Span.zero}])
    end
    ledger.resolve("a").not_nil!.state.leased?.should be_true
  end

  it "renews completed handlers while another handler in their batch is blocked" do
    runtime = JoobQ::Delivery::Runtime.new(JoobQ::RedisStore.instance, "batch-wait-#{UUID.random}",
      capacity: 2, batch_size: 2, lease: 300.milliseconds, poll: 1.millisecond, repair_every: 20.milliseconds)
    count = 0
    blocked = Channel(Nil).new(1)
    release = Channel(Nil).new(1)
    ledger = runtime.register("work") do |raw, context|
      count += 1
      if count == 2
        blocked.send(nil)
        release.receive
      end
      JoobQ::Delivery::Outcome.new
    end
    runtime.admit_many("work", [{"a", "one"}, {"b", "two"}])
    runtime.start
    select
    when blocked.receive
    when timeout(5.seconds)
      fail "second handler did not enter"
    end
    sleep 450.milliseconds
    ledger.claim_many("competitor", 2).should be_empty
    release.send(nil)
    eventually { ledger.resolve_many(["a", "b"]).all? { |r| r.try(&.state.completed?) && r.try(&.attempt) == 1 } }.should be_true
    runtime.stop(2.seconds).clean.should be_true
  ensure
    release.try { |channel| select
    when channel.send(nil)
    else
    end }
    runtime.try(&.stop(1.second))
  end

  it "cancels a bounded batch drain and leaves all unsettled claims recoverable" do
    runtime = JoobQ::Delivery::Runtime.new(JoobQ::RedisStore.instance, "batch-stop-#{UUID.random}",
      capacity: 2, batch_size: 2, lease: 300.milliseconds, poll: 1.millisecond, repair_every: 20.milliseconds)
    blocked = Channel(Nil).new(1)
    release = Channel(Nil).new(1)
    ledger = runtime.register("work") do |raw, context|
      blocked.send(nil)
      release.receive
      JoobQ::Delivery::Outcome.new
    end
    runtime.admit_many("work", [{"a", "one"}, {"b", "two"}])
    runtime.start
    select
    when blocked.receive
    when timeout(5.seconds)
      fail "handler did not enter"
    end
    report = runtime.stop(20.milliseconds)
    report.clean.should be_false
    report.active.should eq(2)
    release.send(nil)
    eventually { runtime.active_count == 0 }.should be_true
    sleep 350.milliseconds
    ledger.repair
    claims = ledger.claim_many("replacement", 2)
    claims.size.should eq(2)
    claims.all? { |c| c.attempt == 2 }.should be_true
    ledger.settle_many(claims.map { |c| {c, JoobQ::Delivery::State::Completed, Time::Span.zero} }).all?(&.applied?).should be_true
  ensure
    release.try { |channel| select
    when channel.send(nil)
    else
    end }
    runtime.try(&.stop(1.second))
  end

  it "renews waiting batch leases and drains without exceeding its slot budget" do
    # Leave room for CI scheduling/AOF stalls and prove renewal from Redis deadlines.
    runtime = JoobQ::Delivery::Runtime.new(JoobQ::RedisStore.instance, "batch-runtime-#{UUID.random}",
      capacity: 4, batch_size: 2, lease: 2.seconds, poll: 1.millisecond, repair_every: 20.milliseconds)
    entered = Channel(Nil).new(4)
    release = Channel(Nil).new
    ids = (0...4).map(&.to_s)
    ledger = runtime.register("work") do |raw, context|
      entered.send(nil)
      release.receive?
      context.check!
      JoobQ::Delivery::Outcome.new
    end
    runtime.admit_many("work", ids.map { |id| {id, "payload"} })
    runtime.start
    2.times do
      select
      when entered.receive
      when timeout(5.seconds)
        fail "batch workers did not enter"
      end
    end
    initial = ledger.resolve_many(ids).map(&.not_nil!)
    initial.all? { |record| record.state.leased? && record.attempt == 1 }.should be_true
    eventually do
      ledger.resolve_many(ids).each_with_index.all? do |record, index|
        record && record.state.leased? && record.attempt == 1 &&
          record.token == initial[index].token && record.lease_until > initial[index].lease_until
      end
    end.should be_true

    # Hold both executing and waiting claims past their original deadlines;
    # merely increasing the lease cannot make a missing renewal pass this test.
    hold_until = Time.unix_ms(initial.max_of(&.lease_until)) + runtime.lease / 2
    sleep({hold_until - Time.utc, Time::Span.zero}.max)
    runtime.active_count.should eq(4)
    ledger.claim_many("competitor", 4).should be_empty
    ledger.resolve_many(ids).all? { |record| record.try(&.state.leased?) && record.try(&.attempt) == 1 }.should be_true
    release.close
    unless eventually { ledger.resolve_many(ids).all? { |record| record.try(&.state.completed?) && record.try(&.attempt) == 1 } }
      states = ledger.resolve_many(ids).map { |record| record.try { |value| {value.state, value.attempt} } }
      fail "Batch did not complete its original attempts: #{states}; #{runtime.metrics.prometheus}"
    end
    runtime.stop(2.seconds).clean.should be_true
  ensure
    # Broadcast release also unblocks any unexpected redelivery during cleanup.
    entered.try(&.close)
    release.try(&.close)
    runtime.try(&.stop(1.second))
  end
end
