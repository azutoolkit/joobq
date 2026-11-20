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

      store.redrive_retained.moved.should eq(1)
      redis.lrange(JoobQ::Keys.queue(name), 0, -1).should eq(["A", "waiting"])
      redis.llen(own).should eq(0)
      InFlight.retained.should be_empty

      store.redrive_retained.moved.should eq(0)
      redis.lrange(JoobQ::Keys.queue(name), 0, -1).should eq(["A", "waiting"])
    end

    it "keeps claim order when several copies are retained" do
      redis.lpush(own, "A", "B", "C")
      %w[A B C].each { |job| retain.call(job) }

      store.redrive_retained.moved.should eq(3)
      redis.lrange(JoobQ::Keys.queue(name), 0, -1).should eq(["A", "B", "C"])
    end

    it "does nothing for a copy another process already reclaimed, and forgets it" do
      retain.call("A")

      store.redrive_retained.moved.should eq(0)
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

    it "reports what it put back and what it could not reach when Redis fails part-way" do
      redis.lpush(own, "A", "B", "C")
      %w[A B C].each { |job| retain.call(job) }
      RedisStore.spec_fail_job = "B" # C is re-driven first (the newest claim goes first), then B fails

      result = store.redrive_retained

      result.moved.should eq(1)
      result.failed.should eq(2) # B and the older A: not reached
      InFlight.retained.map(&.[2]).should eq(["A", "B"])
      redis.lrange(Keys.queue(name), 0, -1).should eq(["C"])

      RedisStore.spec_fail_job = nil
      store.redrive_retained.moved.should eq(2)
      redis.lrange(Keys.queue(name), 0, -1).should eq(["A", "B", "C"])
    end

    it "makes shutdown count exactly the copies it put back plus the ones it could not reach" do
      redis.lpush(own, "A", "B", "C")
      %w[A B C].each { |job| retain.call(job) }
      RedisStore.spec_fail_job = "B"
      before = JoobQ.abandoned_jobs

      JoobQ.drain_retained

      (JoobQ.abandoned_jobs - before).should eq(3) # C put back, B and A unreachable
      InFlight.retained.should be_empty
      RedisStore.spec_fail_job = nil
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
  # the job whose re-drive raises, as a Redis error does when the connection drops
  class_property spec_fail_job : String? = nil

  def redrive_one(queue_name : String, job_json : String) : Int32
    raise Redis::Error.new("connection lost") if job_json == @@spec_fail_job
    previous_def
  end

  def mark_job_completed(job_json : String, queue_name : String) : Bool
    return false if @@spec_cleanup_fails
    previous_def
  end

  def cleanup_job(job_json : String, queue_name : String) : Bool
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

  class RetainFailJob
    include JoobQ::Job

    def initialize(queue : String = "retain_unused", retries : Int32 = 0)
      @queue = queue
      @retries = retries
      @max_retries = retries
    end

    def perform
      raise "boom"
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
      store.redrive_retained.moved.should eq(0)
    end

    # The failure outcome is one script that writes the retry or dead letter AND takes the claim copy off the list, so
    # a cleanup that fails afterwards (Redis away) has nothing to retain and nothing to re-drive.
    it "does not run a dead-lettered job again when the cleanup after it fails" do
      RedisStore.spec_cleanup_fails = true
      queue = Queue(RetainFailJob).new(name, 1)
      JoobQ.queues[name] = queue.not_nil!
      queue.not_nil!.start
      dead_before = DeadLetterQueue.new(redis).count
      job = RetainFailJob.new(name)
      JoobQ.enqueue(name, job.to_json)

      eventually { DeadLetterQueue.new(redis).count > dead_before }.should be_true
      eventually { InFlight.count == 0 }.should be_true
      queue.not_nil!.stop!
      RedisStore.spec_cleanup_fails = false
      InFlight.retained.should be_empty
      store.redrive_retained.moved.should eq(0)
      redis.llen(Keys.queue(name)).should eq(0)
      redis.llen(Keys.processing(name, store.owner_id)).should eq(0)
      redis.hget(Keys.stat("processed"), name).should eq("1") # counted by the failure outcome itself
      redis.zrange(Keys::DEAD_LETTER, 0, -1).each { |entry| redis.zrem(Keys::DEAD_LETTER, entry) if entry.to_s.includes?(name) }
      redis.del(Keys::DEAD_LETTER_COUNTS)
      redis.hdel(Keys.stat("processed"), name)
      redis.hdel(Keys.stat("dead_letter"), name)
    end

    it "does not run a retried job a third time when the cleanup after it fails" do
      RedisStore.spec_cleanup_fails = true
      queue = Queue(RetainFailJob).new(name, 1)
      JoobQ.queues[name] = queue.not_nil!
      queue.not_nil!.start
      job = RetainFailJob.new(name, retries: 1)
      JoobQ.enqueue(name, job.to_json)

      eventually { redis.zrange(RedisStore::DELAYED_SET, 0, -1).any? { |entry| entry.to_s.includes?(job.jid.to_s) } }.should be_true
      eventually { InFlight.count == 0 }.should be_true
      queue.not_nil!.stop!
      RedisStore.spec_cleanup_fails = false
      InFlight.retained.should be_empty
      store.redrive_retained.moved.should eq(0)
      redis.llen(Keys.queue(name)).should eq(0) # only the scheduled retry will run it again
      redis.zrange(RedisStore::DELAYED_SET, 0, -1).each { |entry| redis.zrem(RedisStore::DELAYED_SET, entry) if entry.to_s.includes?(name) }
      redis.hdel(Keys.stat("processed"), name)
      redis.hdel(Keys.stat("retries"), name)
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
