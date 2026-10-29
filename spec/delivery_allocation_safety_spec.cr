require "./spec_helper"

describe "allocation-conscious delivery paths" do
  it "preserves escaped payloads and canonical receipt fields in compact acknowledgments" do
    ledger = JoobQ::Delivery::Ledger.new(JoobQ::RedisStore.instance.redis, "compact-ack", UUID.random.to_s)
    trace = "00-11111111111111111111111111111111-2222222222222222-01"
    payload = "\0\"\\\n日本語" * 1000
    receipt = ledger.admit("single", payload, 1.hour, trace)
    receipt.code.accepted?.should be_true
    entry = receipt.entry.not_nil!
    entry.payload.should eq(payload)
    entry.traceparent.should eq(trace)
    entry.state.scheduled?.should be_true
    entry.due_at.should be > Time.utc.to_unix_ms
    ledger.resolve("single").not_nil!.to_json.should eq(entry.to_json)
    results = ledger.admit_many([{"one", payload}, {"two", payload}], 1.hour, trace)
    results.each_with_index do |result, index|
      result.code.accepted?.should be_true
      ledger.resolve(index == 0 ? "one" : "two").not_nil!.to_json.should eq(result.entry.not_nil!.to_json)
    end
  end

  it "returns the current stored receipt on repeat admissions, including terminal state" do
    ledger = JoobQ::Delivery::Ledger.new(JoobQ::RedisStore.instance.redis, "existing-ack", UUID.random.to_s)
    ledger.admit_many([{"one", "payload"}, {"two", "payload"}])
    claims = ledger.claim_many("worker", 2)
    ledger.settle_many(claims.map { |claim| {claim, JoobQ::Delivery::State::Completed, Time::Span.zero} })
    ledger.admit("one", "payload").entry.not_nil!.state.completed?.should be_true
    ledger.admit_many([{"two", "payload"}])[0].entry.not_nil!.state.completed?.should be_true
    ledger.admit_many([{"one", "different"}])[0].code.rejected?.should be_true
  end

  it "matches standard SHA256 without weakening checksum rejection" do
    ["", "abc", "\0\"\\\n日本語", "x" * 100_000].each do |payload|
      expected = Digest::SHA256.hexdigest(payload)
      JoobQ::Delivery::Checksum.hex(payload).should eq(expected)
      JoobQ::Delivery::Checksum.matches?(payload, expected).should be_true
      JoobQ::Delivery::Checksum.matches?(payload, expected.upcase).should be_false
      JoobQ::Delivery::Checksum.matches?(payload, expected[0, 63]).should be_false
      JoobQ::Delivery::Checksum.matches?(payload + "x", expected).should be_false
    end
  end
end
