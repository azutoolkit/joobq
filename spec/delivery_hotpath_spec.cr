require "./spec_helper"

describe "atomic delivery hot paths" do
  it "preserves opaque payload bytes and exact metadata outside Lua's encoding precision" do
    redis = JoobQ::RedisStore.instance.redis
    ledger = JoobQ::Delivery::Ledger.new(redis, "precision", UUID.random.to_s)
    payload = %({"i":9223372036854775807,"decimal":1.00000000000000001,"text":"héllo 👋 \\"due_at\\":0"})
    admission = ledger.admit("identity", payload)
    entry = admission.entry.not_nil!
    entry.attempt = 9_007_199_254_740_990_i64
    redis.hset(ledger.records_key, entry.id, entry.to_json)
    claim = ledger.claim("owner").not_nil!
    claim.attempt.should eq(9_007_199_254_740_991_i64)
    claim.payload.should eq(payload)
    ledger.renew(claim).applied?.should be_true
    ledger.settle(claim).applied?.should be_true
    final = ledger.resolve("identity").not_nil!
    final.attempt.should eq(claim.attempt)
    final.payload.should eq(payload)
  end

  it "handles concurrent publishers and claimants without duplicate ownership" do
    redis = JoobQ::RedisStore.instance.redis
    ledger = JoobQ::Delivery::Ledger.new(redis, "hot-concurrent", UUID.random.to_s)
    count = 400
    producers = Channel(Exception?).new(8)
    8.times do |producer|
      spawn do
        50.times do |i|
          raise "admission failed" unless ledger.admit("#{producer}-#{i}", "payload").code.accepted?
        end
        producers.send(nil)
      rescue ex
        producers.send(ex)
      end
    end
    8.times { error = producers.receive; raise error if error }
    claims = Channel(JoobQ::Delivery::Claim | Exception | Nil).new(count + 16)
    16.times do |worker|
      spawn do
        while claim = ledger.claim("owner-#{worker}")
          raise "settlement failed" unless ledger.settle(claim).applied?
          claims.send(claim)
        end
        claims.send(nil)
      rescue ex
        claims.send(ex)
      end
    end
    identities = Set(String).new
    finished = 0
    until finished == 16
      select
      when claim = claims.receive
        case claim
        when Exception
          raise claim
        when Nil
          finished += 1
        else
          identities.add?(claim.id).should be_true
          claim.attempt.should eq(1)
        end
      when timeout(10.seconds)
        fail "concurrent claimants did not drain"
      end
    end
    identities.size.should eq(count)
    redis.zcard(ledger.ready_key).should eq(0)
    redis.zcard(ledger.leases_key).should eq(0)
  end

  it "reloads an evicted script but never confuses a wrong-type write with NOSCRIPT" do
    redis = JoobQ::RedisStore.instance.redis
    ledger = JoobQ::Delivery::Ledger.new(redis, "script-cache", UUID.random.to_s)
    ledger.admit("one", "payload").code.accepted?.should be_true
    redis.command(["SCRIPT", "FLUSH"])
    ledger.admit("two", "payload").code.accepted?.should be_true
    claim = ledger.claim("owner").not_nil!
    redis.command(["SCRIPT", "FLUSH"])
    ledger.settle(claim).applied?.should be_true
    redis.del(ledger.ready_key)
    redis.set(ledger.ready_key, "invalid index")
    ledger.admit("three", "payload").code.unknown?.should be_true
    ledger.resolve("three").should_not be_nil
  end

  it "rejects altered payload bytes before acknowledging an owned lease" do
    redis = JoobQ::RedisStore.instance.redis
    ledger = JoobQ::Delivery::Ledger.new(redis, "corrupt-owned", UUID.random.to_s)
    admission = ledger.admit("id", "payload")
    claim = ledger.claim("owner").not_nil!
    raw = redis.hget(ledger.records_key, admission.id).not_nil!
    changed = JSON.parse(raw)
    changed.as_h["payload"] = JSON::Any.new("tampered")
    redis.hset(ledger.records_key, admission.id, changed.to_json)
    expect_raises(JoobQ::Delivery::CorruptRecord) { ledger.settle(claim) }
    redis.hget(ledger.records_key, admission.id).should eq(changed.to_json)
  end
end

describe "optimized claim integrity" do
  it "preserves original corrupt bytes before executing a handler" do
    redis = JoobQ::RedisStore.instance.redis
    ledger = JoobQ::Delivery::Ledger.new(redis, "claim-integrity", UUID.random.to_s)
    receipt = ledger.admit("id", "payload")
    damaged = JSON.parse(redis.hget(ledger.records_key, receipt.id).not_nil!)
    damaged.as_h["payload"] = JSON::Any.new("damaged")
    original = damaged.to_json
    redis.hset(ledger.records_key, receipt.id, original)
    ledger.claim("worker").should be_nil
    redis.hget(ledger.records_key, receipt.id).should eq(original)
    redis.hget(ledger.quarantine_key, receipt.id).should eq(original)
    redis.zcard(ledger.leases_key).should eq(0)
    redis.zcard(ledger.ready_key).should eq(0)
  end
end
