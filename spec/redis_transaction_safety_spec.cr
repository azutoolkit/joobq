require "./spec_helper"

describe "Redis transaction connection hygiene" do
  it "discards buffered MULTI bytes when application code aborts the block" do
    store = JoobQ::RedisStore.new(pool_size: 1)
    expect_raises(ArgumentError, "abort transaction") do
      store.redis.multi do |tx|
        tx.set("aborted-transaction", "must-not-commit")
        raise ArgumentError.new("abort transaction")
      end
    end
    store.redis.ping.should eq("PONG")
    store.redis.get("aborted-transaction").should be_nil
    store.redis.set("after-abort", "stored").should eq("OK")
  ensure
    store.try(&.close)
  end

  it "closes unread EXEC replies without replaying already executed mutations" do
    store = JoobQ::RedisStore.new(pool_size: 1)
    store.redis.set("transaction-wrong-type", "value")
    expect_raises(Redis::Error) do
      store.redis.multi do |tx|
        tx.lpush("transaction-wrong-type", "bad")
        tx.incr("transaction-effect")
      end
    end
    store.redis.ping.should eq("PONG")
    # Redis executes the other commands even when one EXEC element errors.
    store.redis.get("transaction-effect").should eq("1")
  ensure
    store.try(&.close)
  end
end
