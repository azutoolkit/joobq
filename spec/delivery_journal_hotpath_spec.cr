require "./spec_helper"

private class JournalHotpathDocument
  include JSON::Serializable
  property payload : String

  def initialize(@payload)
  end
end

describe JoobQ::Delivery::Journal do
  it "reloads cached scripts and retains byte-exact CAS across buffer growth" do
    redis = JoobQ.store.as(JoobQ::RedisStore).redis
    journal = JoobQ::Delivery::Journal(JournalHotpathDocument).new(redis, "journal-spec", "growth")
    doc = JournalHotpathDocument.new("small")
    journal.write("id", doc).should be_true
    _, old = journal.read("id").not_nil!
    redis.command(["SCRIPT", "FLUSH"])
    doc.payload = "☃\n\"\\" * 1000
    journal.write("id", doc, old).should be_true
    journal.read("id").not_nil![0].payload.should eq(doc.payload)
    journal.write("id", JournalHotpathDocument.new("stale"), old).should be_false
  end

  it "rejects capacity and size overflow without replacing authoritative bytes" do
    redis = JoobQ.store.as(JoobQ::RedisStore).redis
    journal = JoobQ::Delivery::Journal(JournalHotpathDocument).new(redis, "journal-spec", "bounds", capacity: 1, max_bytes: 64)
    doc = JournalHotpathDocument.new("original")
    journal.write("one", doc).should be_true
    _, raw = journal.read("one").not_nil!
    expect_raises(ArgumentError, /capacity/) { journal.write("two", doc) }
    expect_raises(ArgumentError, /byte limit/) { journal.write("one", JournalHotpathDocument.new("x" * 100), raw) }
    journal.read("one").not_nil![1].should eq(raw)
  end

  it "preserves corrupt source bytes when quarantine cannot be written" do
    redis = JoobQ.store.as(JoobQ::RedisStore).redis
    journal = JoobQ::Delivery::Journal(JournalHotpathDocument).new(redis, "journal-spec", "quarantine")
    redis.hset(journal.key, "corrupt", "invalid-json")
    redis.set(journal.quarantine_key, "wrong-type")
    expect_raises(Redis::Error) { journal.each_page { |_| } }
    redis.hget(journal.key, "corrupt").should eq("invalid-json")
    redis.del(journal.quarantine_key)
    redis.command(["SCRIPT", "FLUSH"])
    journal.each_page { |_| }
    redis.hget(journal.quarantine_key, "corrupt").should eq("invalid-json")
  end

  it "allows only one concurrent replacement of the same raw version" do
    journal = JoobQ::Delivery::Journal(JournalHotpathDocument).new(JoobQ.store.redis, "journal-spec", "cas")
    journal.write("id", JournalHotpathDocument.new("initial"))
    _, raw = journal.read("id").not_nil!
    done = Channel(Bool | Exception).new(32)
    32.times do |index|
      spawn do
        done.send(journal.write("id", JournalHotpathDocument.new(index.to_s), raw))
      rescue ex
        done.send(ex)
      end
    end
    wins = 0
    32.times do
      select
      when result = done.receive
        raise result if result.is_a?(Exception)
        wins += 1 if result
      when timeout(5.seconds)
        fail "journal CAS stalled"
      end
    end
    wins.should eq(1)
  end
end
