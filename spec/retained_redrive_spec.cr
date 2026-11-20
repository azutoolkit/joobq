require "./spec_helper"

# A job whose outcome could not be stored (Redis was away when it ended) keeps its copy in this process's own
# processing list. The owner re-drives that copy to the head of its queue itself, once: a live process's heartbeat
# is current again by then, so no other process reclaims it.
module JoobQ
  describe "re-driving retained processing copies" do
    store = JoobQ.store.as(RedisStore)
    redis = store.redis
    name = "retained_spec"
    own = "joobq:v1:processing:#{name}:#{store.owner_id}"

    # A claim that ended without its outcome stored: claimed, run, then retained instead of dropped.
    retain = ->(job : String) do
      token = InFlight.claimed(name, [job]).first
      InFlight.begin_run(token)
      InFlight.finishing(token).should be_false
      InFlight.done(token, retain: true)
    end

    before_each do
      InFlight.clear
      redis.del(JoobQ::Keys.queue(name), own)
    end
    after_each do
      InFlight.clear
      redis.del(JoobQ::Keys.queue(name), own)
    end

    it "puts a retained copy back at the head of its queue, and a second pass does nothing" do
      redis.rpush(JoobQ::Keys.queue(name), "waiting")
      redis.lpush(own, "A")
      retain.call("A")

      store.redrive_retained.should eq(1)
      redis.lrange(JoobQ::Keys.queue(name), 0, -1).should eq(["A", "waiting"])
      redis.llen(own).should eq(0)
      InFlight.retained.should be_empty

      store.redrive_retained.should eq(0)
      redis.lrange(JoobQ::Keys.queue(name), 0, -1).should eq(["A", "waiting"])
    end

    it "keeps claim order when several copies are retained" do
      redis.lpush(own, "A", "B", "C")
      %w[A B C].each { |job| retain.call(job) }

      store.redrive_retained.should eq(3)
      redis.lrange(JoobQ::Keys.queue(name), 0, -1).should eq(["A", "B", "C"])
    end

    it "does nothing for a copy another process already reclaimed, and forgets it" do
      retain.call("A")

      store.redrive_retained.should eq(0)
      redis.exists(JoobQ::Keys.queue(name)).should eq(0)
      InFlight.retained.should be_empty
    end

    it "is done by the owner heartbeat loop on its own" do
      redis.lpush(own, "A")
      retain.call("A")
      store.stop_owner_heartbeat
      store.start_owner_heartbeat
      begin
        50.times { break if redis.llen(JoobQ::Keys.queue(name)) == 1; sleep 50.milliseconds }
        redis.lrange(JoobQ::Keys.queue(name), 0, -1).should eq(["A"])
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

    it "keeps retained copies out of abandon_all: shutdown drains them on their own" do
      retain.call("A")
      InFlight.abandon_all.should be_empty
      InFlight.abandon_all(settling: true).should be_empty
      InFlight.retained.map(&.[2]).should eq(["A"])
    end

    describe "a claim whose cleanup is running" do
      start = -> do
        token = InFlight.claimed(name, ["A"]).first
        InFlight.begin_run(token)
        token
      end

      it "stays counted while the cleanup runs, and is forgotten when it stored the outcome" do
        token = start.call
        InFlight.finishing(token).should be_false
        InFlight.count.should eq(1)
        InFlight.any?(name).should be_true
        InFlight.done(token, retain: false)
        InFlight.count.should eq(0)
        InFlight.retained.should be_empty
      end

      it "becomes retained, under its own token, when the cleanup could not store the outcome" do
        token = start.call
        InFlight.finishing(token)
        InFlight.done(token, retain: true)
        InFlight.count.should eq(0)
        InFlight.retained.should eq([{token, name, "A"}])
      end

      it "is left to finish by the usual abandon pass, and taken by the last resort" do
        token = start.call
        InFlight.finishing(token)
        InFlight.abandon_all.should be_empty
        InFlight.abandon_all(settling: true).should eq([{name, "A"}])
        InFlight.done(token, retain: true) # shutdown returned it already: nothing is kept
        InFlight.retained.should be_empty
        InFlight.count.should eq(0)
      end

      it "says so when shutdown abandoned the claim before its fiber finished" do
        token = start.call
        InFlight.abandon_all
        InFlight.finishing(token).should be_true
        InFlight.count.should eq(0)
      end
    end
  end
end

# Specs only: a store whose cleanup of a finished job fails, as it does while Redis is away. The copy stays in the list.
class JoobQ::RedisStore
  class_property spec_cleanup_fails = false

  def mark_job_completed(job_json : String, queue_name : String) : Bool
    return false if @@spec_cleanup_fails
    previous_def
  end
end

module JoobQ
  class RetainWorkerJob
    include JoobQ::Job

    RAN = Atomic(Int32).new(0)

    def initialize(queue : String = "retain_unused")
      @queue = queue
    end

    def perform
      RAN.add(1)
    end
  end

  describe "a worker whose cleanup could not be stored" do
    store = JoobQ.store.as(RedisStore)
    redis = store.redis
    name = ""
    queue = nil.as(Queue(RetainWorkerJob)?)

    before_each do
      name = "retain_worker_#{Random::Secure.hex(3)}"
      InFlight.clear
      RetainWorkerJob::RAN.set(0)
      RedisStore.spec_cleanup_fails = false
    end

    after_each do
      RedisStore.spec_cleanup_fails = false
      queue.try(&.stop!)
      JoobQ.queues.delete(name)
      InFlight.clear
      redis.del(Keys.queue(name), Keys.processing(name, store.owner_id))
    end

    it "keeps the copy of a job that succeeded, then re-drives it, once, when Redis is back" do
      RedisStore.spec_cleanup_fails = true
      queue = Queue(RetainWorkerJob).new(name, 1)
      JoobQ.queues[name] = queue.not_nil!
      queue.not_nil!.start
      JoobQ.enqueue(name, RetainWorkerJob.new(name).to_json)

      eventually { InFlight.retained.size >= 1 }.should be_true
      queue.not_nil!.stop!
      RedisStore.spec_cleanup_fails = false
      store.redrive_retained
      InFlight.retained.should be_empty
      redis.llen(Keys.processing(name, store.owner_id)).should eq(0)
      redis.llen(Keys.queue(name)).should eq(1) # run again: at-least-once
      store.redrive_retained.should eq(0)
    end

    it "reads a 0.6 job (no format version) through a worker, and finishes it" do
      queue = Queue(RetainWorkerJob).new(name, 1)
      JoobQ.queues[name] = queue.not_nil!
      queue.not_nil!.start
      old = JSON.parse(RetainWorkerJob.new(name).to_json).as_h.reject("v").to_json
      old.should_not contain("\"v\"")
      redis.rpush(Keys.queue(name), old)

      eventually { RetainWorkerJob::RAN.get == 1 && redis.llen(Keys.queue(name)) == 0 }.should be_true
      eventually { redis.llen(Keys.processing(name, store.owner_id)) == 0 }.should be_true
    end

    it "dead-letters a job of a newer format version unread, and does not run it" do
      queue = Queue(RetainWorkerJob).new(name, 1)
      JoobQ.queues[name] = queue.not_nil!
      queue.not_nil!.start
      future = JSON.parse(RetainWorkerJob.new(name).to_json).as_h.merge({"v" => JSON::Any.new(2_i64)}).to_json
      dead_before = DeadLetterQueue.new(redis).count
      redis.rpush(Keys.queue(name), future)

      eventually { DeadLetterQueue.new(redis).count > dead_before }.should be_true
      RetainWorkerJob::RAN.get.should eq(0)
      kept = redis.zrange(Keys::DEAD_LETTER, 0, -1).map(&.to_s).find { |entry| entry.includes?(name) }.not_nil!
      JSON.parse(kept)["original_job_data"].as_s.should eq(future) # the payload is kept whole, for a redrive after the upgrade
      eventually { redis.llen(Keys.processing(name, store.owner_id)) == 0 }.should be_true
      redis.zremrangebyscore(Keys::DEAD_LETTER, "-inf", "+inf")
      redis.del(Keys::DEAD_LETTER_COUNTS)
    end
  end
end
