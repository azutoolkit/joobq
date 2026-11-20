require "./spec_helper"

# A job whose outcome could not be stored (Redis was away when it ended) keeps its copy in this process's own
# processing list. The owner re-drives that copy to the head of its queue itself, once: a live process's heartbeat
# is current again by then, so no other process reclaims it.
module JoobQ
  describe "re-driving retained processing copies" do
    store = JoobQ.store.as(RedisStore)
    redis = store.redis
    name = "retained_spec"
    own = "joobq:processing:#{name}:#{store.owner_id}"

    # A claim that ended without its outcome stored: claimed, run, then retained instead of dropped.
    retain = ->(job : String) do
      token = InFlight.claimed(name, [job]).first
      InFlight.begin_run(token)
      InFlight.finished(token, retain: true).should be_false
      token
    end

    before_each do
      InFlight.clear
      redis.del(name, own)
    end
    after_each do
      InFlight.clear
      redis.del(name, own)
    end

    it "puts a retained copy back at the head of its queue, and a second pass does nothing" do
      redis.rpush(name, "waiting")
      redis.lpush(own, "A")
      retain.call("A")

      store.redrive_retained.should eq(1)
      redis.lrange(name, 0, -1).should eq(["A", "waiting"])
      redis.llen(own).should eq(0)
      InFlight.retained.should be_empty

      store.redrive_retained.should eq(0)
      redis.lrange(name, 0, -1).should eq(["A", "waiting"])
    end

    it "keeps claim order when several copies are retained" do
      redis.lpush(own, "A", "B", "C")
      %w[A B C].each { |job| retain.call(job) }

      store.redrive_retained.should eq(3)
      redis.lrange(name, 0, -1).should eq(["A", "B", "C"])
    end

    it "does nothing for a copy another process already reclaimed, and forgets it" do
      retain.call("A")

      store.redrive_retained.should eq(0)
      redis.exists(name).should eq(0)
      InFlight.retained.should be_empty
    end

    it "is done by the owner heartbeat loop on its own" do
      redis.lpush(own, "A")
      retain.call("A")
      store.stop_owner_heartbeat
      store.start_owner_heartbeat
      begin
        50.times { break if redis.llen(name) == 1; sleep 50.milliseconds }
        redis.lrange(name, 0, -1).should eq(["A"])
        redis.llen(own).should eq(0)
      ensure
        store.stop_owner_heartbeat
      end
    end

    it "does not count a retained copy as running" do
      retain.call("A")
      InFlight.count.should eq(0)
      InFlight.any?(name).should be_false
    end

    it "hands retained copies to abandon_all, so shutdown counts them" do
      retain.call("A")
      InFlight.abandon_all.should eq([{name, "A"}])
    end
  end
end
