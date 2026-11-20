require "./spec_helper"

class DefaultQueueJob
  include JoobQ::Job

  def initialize
    @queue = "default"
  end

  def perform
  end
end

# Every key JoobQ writes lives under one versioned namespace, `joobq:v1:`, so it cannot collide with another
# application's keys on a shared Redis and a later layout change is detectable.
module JoobQ
  describe "the keyspace" do
    store = JoobQ.store.as(RedisStore)
    redis = store.redis

    all_keys = -> do
      keys = [] of String
      cursor = "0"
      loop do
        reply = redis.scan(cursor, count: 1000)
        cursor = reply[0].as(String)
        keys.concat(reply[1].as(Array).map(&.as(String)))
        break if cursor == "0"
      end
      keys.to_set
    end

    before_each { redis.del(Keys.queue("default")) }
    after_each { redis.del(Keys.queue("default")) }

    describe Keys do
      it "names the queue list inside the namespace" do
        Keys::PREFIX.should eq("joobq:v1")
        Keys.queue("default").should eq("joobq:v1:queue:default")
      end
    end

    it "enqueue to the queue `default` writes only joobq:v1:* keys" do
      before = all_keys.call
      store.enqueue(DefaultQueueJob.new)

      written = all_keys.call - before
      written.should eq(["joobq:v1:queue:default"].to_set)
      redis.llen("default").should eq(0) # no bare key
    end

    it "claims, counts and lists the queue through the same key" do
      store.enqueue(DefaultQueueJob.new)
      store.queue_size("default").should eq(1)
      store.list_jobs("default").size.should eq(1)
      store.claim_job("default", "w1", DefaultQueueJob).should_not be_nil
      store.queue_size("default").should eq(0)
      redis.del("joobq:v1:processing:default:#{store.owner_id}", "joobq:processing:default:#{store.owner_id}")
    end
  end
end
