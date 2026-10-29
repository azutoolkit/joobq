require "./spec_helper"

private def with_delivery_ledger(&)
  redis = JoobQ::RedisStore.instance.redis
  ledger = JoobQ::Delivery::Ledger.new(redis, "spec", UUID.random.to_s)
  yield ledger, redis
ensure
  redis.try &.del(ledger.records_key, ledger.ready_key, ledger.leases_key) if ledger
end

describe JoobQ::Delivery::Ledger do
  it "admits concurrent identical requests once and rejects conflicting payloads" do
    with_delivery_ledger do |ledger, redis|
      results = Channel(JoobQ::Delivery::Admission | Exception).new(40)
      40.times do
        spawn do
          results.send(ledger.admit("stable-request", %({"number":9223372036854775807})))
        rescue ex
          results.send(ex)
        end
      end
      40.times do
        select
        when result = results.receive
          raise result if result.is_a?(Exception)
          result.code.should eq(JoobQ::Delivery::AdmissionCode::Accepted)
        when timeout(10.seconds)
          fail "concurrent admission hung"
        end
      end
      redis.hlen(ledger.records_key).should eq(1)
      redis.zcard(ledger.ready_key).should eq(1)
      ledger.resolve("stable-request").not_nil!.payload.should eq(%({"number":9223372036854775807}))
      ledger.admit("stable-request", "different").code.should eq(JoobQ::Delivery::AdmissionCode::Rejected)
    end
  end

  it "allows one concurrent claimant and idempotent terminal settlement" do
    with_delivery_ledger do |ledger, redis|
      ledger.admit("job", "opaque")
      results = Channel(JoobQ::Delivery::Claim? | Exception).new(20)
      20.times do |n|
        spawn do
          results.send(ledger.claim("worker-#{n}"))
        rescue ex
          results.send(ex)
        end
      end
      claims = [] of JoobQ::Delivery::Claim
      20.times do
        select
        when result = results.receive
          raise result if result.is_a?(Exception)
          claims << result if result
        when timeout(10.seconds)
          fail "concurrent claim hung"
        end
      end
      claims.size.should eq(1)
      claim = claims.first
      ledger.renew(claim).should eq(JoobQ::Delivery::Settlement::Applied)
      ledger.settle(claim).should eq(JoobQ::Delivery::Settlement::Applied)
      ledger.settle(claim).should eq(JoobQ::Delivery::Settlement::AlreadyApplied)
      ledger.renew(claim).should eq(JoobQ::Delivery::Settlement::Stale)
      redis.hlen(ledger.records_key).should eq(1)
      redis.zcard(ledger.ready_key).should eq(0)
      redis.zcard(ledger.leases_key).should eq(0)
    end
  end

  it "repairs an expired lease and fences the previous owner" do
    with_delivery_ledger do |ledger, redis|
      ledger.admit("job", "opaque")
      old = ledger.claim("old", 50.milliseconds).not_nil!
      sleep 80.milliseconds
      ledger.renew(old).should eq(JoobQ::Delivery::Settlement::Stale)
      ledger.settle(old).should eq(JoobQ::Delivery::Settlement::Stale)
      cursor = "0"
      loop do
        cursor = ledger.repair(cursor)
        break if cursor == "0"
      end
      current = ledger.claim("new").not_nil!
      current.attempt.should eq(2)
      current.token.should_not eq(old.token)
      ledger.settle(old).should eq(JoobQ::Delivery::Settlement::Stale)
      ledger.settle(current).should eq(JoobQ::Delivery::Settlement::Applied)
    end
  end

  it "keeps canonical admission after an index failure and repairs discoverability" do
    with_delivery_ledger do |ledger, redis|
      redis.set(ledger.ready_key, "wrong type")
      ledger.admit("job", "opaque").code.should eq(JoobQ::Delivery::AdmissionCode::Unknown)
      ledger.resolve("job").not_nil!.state.should eq(JoobQ::Delivery::State::Ready)
      redis.del(ledger.ready_key)
      ledger.repair
      ledger.claim("worker").not_nil!.payload.should eq("opaque")
      redis.hlen(ledger.records_key).should eq(1)
    end
  end

  it "resolves a terminal write after derived-index failure without reexecuting it" do
    with_delivery_ledger do |ledger, redis|
      ledger.admit("job", "opaque")
      claim = ledger.claim("worker").not_nil!
      redis.del(ledger.leases_key)
      redis.set(ledger.leases_key, "wrong type")
      ledger.settle(claim).should eq(JoobQ::Delivery::Settlement::Unknown)
      ledger.resolve("job").not_nil!.state.should eq(JoobQ::Delivery::State::Completed)
      redis.del(ledger.leases_key)
      ledger.repair
      ledger.settle(claim).should eq(JoobQ::Delivery::Settlement::AlreadyApplied)
      ledger.claim("other").should be_nil
    end
  end

  it "validates the lease deadline inside the atomic CAS" do
    with_delivery_ledger do |ledger, redis|
      admission = ledger.admit("job", "opaque")
      claim = ledger.claim("worker", 50.milliseconds).not_nil!
      raw = redis.hget(ledger.records_key, admission.id).not_nil!
      entry = JoobQ::Delivery::Record.from_json(raw)
      deadline = entry.lease_until
      entry.state = JoobQ::Delivery::State::Completed
      entry.lease_until = 0_i64
      sleep 80.milliseconds
      redis.eval(JoobQ::Delivery::Ledger::WRITE,
        [ledger.records_key, ledger.ready_key, ledger.leases_key, ledger.gate_key],
        [claim.id, raw, entry.to_json, "", "", deadline.to_s, "", "100000"]).should eq(0)
      redis.hget(ledger.records_key, admission.id).should eq(raw)
    end
  end

  it "schedules redelivery with a fresh token and fails closed on corrupt envelopes" do
    with_delivery_ledger do |ledger, redis|
      admission = ledger.admit("job", "opaque")
      claim = ledger.claim("worker").not_nil!
      ledger.settle(claim, JoobQ::Delivery::State::Scheduled, 60.milliseconds).should eq(JoobQ::Delivery::Settlement::Applied)
      ledger.claim("early").should be_nil
      sleep 80.milliseconds
      ledger.claim("later").not_nil!.attempt.should eq(2)
      ledger.settle(claim).should eq(JoobQ::Delivery::Settlement::Stale)
      redis.hset(ledger.records_key, admission.id, "invalid")
      expect_raises(JoobQ::Delivery::CorruptRecord) { ledger.resolve("job") }
      expect_raises(ArgumentError) { ledger.admit("", "payload") }
      ledger.admit("empty", "").code.should eq(JoobQ::Delivery::AdmissionCode::Rejected)
    end
  end
end
