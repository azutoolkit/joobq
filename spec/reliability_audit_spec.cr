require "./spec_helper"

# Reliability guarantees of the open-source engine, pinned as they are (not as one would like them to be): crash
# recovery windows and duplicates, poison pills, the retry lock, sealed payloads and the leased Delivery runtime.

class AuditMixedJob
  include JoobQ::Job

  COMPLETED = Atomic(Int32).new(0)
  ATTEMPTS  = Atomic(Int32).new(0)

  property poison : Bool = false

  def initialize(@poison : Bool = false)
    @queue = "audit_mixed"
    @expires = 1.hour.from_now.to_unix_ms
  end

  def perform
    if poison
      ATTEMPTS.add(1)
      raise "poison pill"
    end
    COMPLETED.add(1)
  end
end

# Another class whose payloads land on AuditMixedJob's queue: every field it lacks has a default there.
class AuditOtherJob
  include JoobQ::Job

  property note : String = "meant for another class"

  def initialize
    @queue = "audit_mixed"
  end

  def perform
  end
end

# A class with a field that has no default: a payload without it cannot be loaded.
class AuditStrictJob
  include JoobQ::Job

  property needed : String

  def initialize(@needed : String)
    @queue = "audit_strict"
  end

  def perform
  end
end

class AuditSealedJob
  include JoobQ::Job

  encrypted_property token : String = ""

  def initialize(@token : String = "")
    @queue = "audit_sealed"
  end

  def perform
  end
end

# Poses as a Redis that drops the connection right after the retry was written, while the failed copy is being
# taken off the processing list.
class AuditFlakyRemovalStore < JoobQ::RedisStore
  property failures_left = 0

  private def remove_job_from_processing_by_id(job_id : String, queue_name : String) : Bool
    if @failures_left > 0
      @failures_left -= 1
      raise Redis::Error.new("simulated: connection lost after the retry was stored")
    end
    super
  end
end

AUDIT_KEY_A = "a1:" + "11" * 32
AUDIT_KEY_C = "c3:" + "33" * 32

private def audit_entries(redis, key : String, queue : String) : Array(JSON::Any)
  redis.zrange(key, 0, -1).map { |raw| JSON.parse(raw.to_s) }.select { |job| job["queue"]? == queue }
end

private def audit_raw(sealed : String) : Bytes
  Base64.decode(sealed.rpartition(':')[2].tr("-_", "+/"))
end

private def audit_reseal(sealed : String, & : Bytes ->) : String
  raw = audit_raw(sealed)
  yield raw
  "#{sealed.rpartition(':')[0]}:#{Base64.urlsafe_encode(raw, padding: false)}"
end

module JoobQ
  describe "reliability audit" do
    store = JoobQ.store.as(RedisStore)
    redis = store.redis

    before_each do
      AuditMixedJob::COMPLETED.set(0)
      AuditMixedJob::ATTEMPTS.set(0)
    end

    after_each do
      eventually(2.seconds) { store.processing_queue_size("audit_mixed") == 0 && store.processing_queue_size("audit_strict") == 0 }
      sleep 50.milliseconds
      JoobQ.reset
    end

    describe "A. claims of a crashed process" do
      list_of = ->(queue : String, owner : String) { "joobq:processing:#{queue}:#{owner}" }

      it "are not recovered while the crashed owner's last heartbeat is younger than 30 s, and go to the head once it is older" do
        crashed = "crashed-host:4242"
        redis.rpush("example", "WAITING")
        claimed = ExampleJob.new(1).to_json
        redis.lpush(list_of.call("example", crashed), claimed)

        # SIGKILL skips stop_owner_heartbeat: the entry stays with its last beat
        redis.zadd(RedisStore::OWNERS, store.redis_now_ms - 29_000, crashed)
        store.recover_orphaned_processing("example").should eq(0)
        redis.lrange("example", 0, -1).should eq(["WAITING"])

        redis.zadd(RedisStore::OWNERS, store.redis_now_ms - 31_000, crashed)
        store.recover_orphaned_processing("example").should eq(1)
        redis.lrange("example", 0, -1).should eq([claimed, "WAITING"])
        redis.zscore(RedisStore::OWNERS, crashed).should be_nil # pruned as it was read
      end

      it "are not taken by the restarted process's own start-up recovery (new pid, new owner); a reaper pass takes them once the heartbeat lapsed" do
        crashed = "crashed-host:4243"
        claimed = ExampleJob.new(2).to_json
        redis.lpush(list_of.call("example", crashed), claimed)
        redis.zadd(RedisStore::OWNERS, store.redis_now_ms - 5_000, crashed)

        # what Queue#start does for this (new) process
        store.move_job_back_to_queue("example", include_self: true).should be_false
        redis.llen("example").should eq(0)

        redis.zadd(RedisStore::OWNERS, store.redis_now_ms - 31_000, crashed)
        ExpiredJobReaper.new(store: store, interval: 1.hour).reap_once
        redis.lrange("example", 0, -1).should eq([claimed])
        redis.exists(list_of.call("example", crashed)).should eq(0)
      end

      it "run twice, not never, when the crash fell between writing the retry and removing the failed copy" do
        crashed = "crashed-host:4244"
        original = ExampleJob.new(3)
        redis.lpush(list_of.call("example", crashed), original.to_json)
        retried = ExampleJob.from_json(original.to_json)
        retried.retries -= 1
        retried.retrying!
        store.schedule_job(retried.to_json, store.redis_now_ms - 1) # the retry was already written, and is due

        store.recover_orphaned_processing("example").should eq(1)
        store.promote_due_jobs(Time.utc, queue_name: "example")
        copies = redis.lrange("example", 0, -1).count { |raw| JSON.parse(raw.to_s)["jid"] == original.jid.to_s }
        copies.should eq(2)
      end
    end

    describe "B. poison pills" do
      it "a job that always raises is retried and dead-lettered without holding back the jobs behind it" do
        queue = Queue(AuditMixedJob).new("audit_mixed", 1)
        poison = AuditMixedJob.new(true)
        poison.retries = 2
        poison.max_retries = 2
        JoobQ.add(poison)
        20.times { JoobQ.add(AuditMixedJob.new) }
        worker = Worker(AuditMixedJob).new(1, Channel(Nil).new, queue)
        worker.run

        eventually { AuditMixedJob::COMPLETED.get == 20 && AuditMixedJob::ATTEMPTS.get == 1 }.should be_true
        2.times do |attempt|
          eventually { audit_entries(redis, RedisStore::DELAYED_SET, "audit_mixed").size == 1 }.should be_true
          store.promote_due_jobs(1.hour.from_now, queue_name: "audit_mixed")
          eventually { AuditMixedJob::ATTEMPTS.get == attempt + 2 }.should be_true
        end

        eventually { audit_entries(redis, DeadLetterQueue::KEY, "audit_mixed").size == 1 }.should be_true
        AuditMixedJob::ATTEMPTS.get.should eq(3)
        audit_entries(redis, RedisStore::DELAYED_SET, "audit_mixed").should be_empty
        eventually { store.processing_queue_size("audit_mixed") == 0 }.should be_true
      ensure
        worker.try(&.terminate)
      end

      it "a payload that is not JSON is dead-lettered as a stub and the next job runs" do
        queue = Queue(AuditMixedJob).new("audit_mixed", 1)
        redis.rpush("audit_mixed", %({"jid": "not-a-job))
        JoobQ.add(AuditMixedJob.new)
        worker = Worker(AuditMixedJob).new(1, Channel(Nil).new, queue)
        worker.run

        eventually { AuditMixedJob::COMPLETED.get == 1 && audit_entries(redis, DeadLetterQueue::KEY, "audit_mixed").size == 1 }.should be_true
        dead = audit_entries(redis, DeadLetterQueue::KEY, "audit_mixed").first
        dead["error"]["error_type"].should eq("serialization_error")
        eventually { store.processing_queue_size("audit_mixed") == 0 }.should be_true
      ensure
        worker.try(&.terminate)
      end

      it "has no class check: another class's payload whose fields fit runs as the queue's class, with its defaults" do
        queue = Queue(AuditMixedJob).new("audit_mixed", 1)
        redis.rpush("audit_mixed", AuditOtherJob.new.to_json)
        worker = Worker(AuditMixedJob).new(1, Channel(Nil).new, queue)
        worker.run

        eventually { AuditMixedJob::COMPLETED.get == 1 }.should be_true
        audit_entries(redis, DeadLetterQueue::KEY, "audit_mixed").should be_empty
      ensure
        worker.try(&.terminate)
      end

      it "dead-letters another class's payload that lacks a field the queue's class requires" do
        queue = Queue(AuditStrictJob).new("audit_strict", 1)
        foreign = AuditMixedJob.new
        foreign.queue = "audit_strict"
        redis.rpush("audit_strict", foreign.to_json)
        worker = Worker(AuditStrictJob).new(1, Channel(Nil).new, queue)
        worker.run

        eventually { audit_entries(redis, DeadLetterQueue::KEY, "audit_strict").size == 1 }.should be_true
        audit_entries(redis, DeadLetterQueue::KEY, "audit_strict").first["jid"].should eq(foreign.jid.to_s)
      ensure
        worker.try(&.terminate)
      end
    end

    describe "C. retry lock and enqueue idempotency" do
      it "takes the retry lock in one script: concurrent handlers of one failure schedule one retry" do
        queue = Queue(AuditMixedJob).new("audit_mixed", 1)
        json = AuditMixedJob.new(true).to_json
        results = Channel(Bool).new(10)
        10.times do
          spawn do
            job = AuditMixedJob.from_json(json)
            job.retries = 2
            ok, _ = ExponentialBackoff.retry_idempotent(job, queue, 1)
            results.send(ok)
          end
        end
        outcomes = Array(Bool).new(10) { results.receive }
        outcomes.count(&.itself).should eq(1)
        audit_entries(redis, RedisStore::DELAYED_SET, "audit_mixed").size.should eq(1)
      end

      it "does not dead-letter a job whose retry was stored when taking it off the processing list fails" do
        flaky = AuditFlakyRemovalStore.new
        flaky.failures_left = 1
        queue = Queue(AuditMixedJob).new("audit_mixed", 1, store: flaky)
        job = AuditMixedJob.new(true)
        job.retries = 2
        job.max_retries = 2
        redis.lpush("joobq:processing:audit_mixed:#{flaky.owner_id}", job.to_json)

        Middleware::Retry.new.call(job, queue, "w", Proc(Nil).new { raise "boom" })

        audit_entries(redis, RedisStore::DELAYED_SET, "audit_mixed").size.should eq(1)
        audit_entries(redis, DeadLetterQueue::KEY, "audit_mixed").should be_empty
      ensure
        flaky.try(&.close)
        redis.del("joobq:processing:audit_mixed:#{store.owner_id}")
      end

      it "has no enqueue deduplication: the same job enqueued twice is queued twice" do
        job = ExampleJob.new(7)
        JoobQ.add(job)
        JoobQ.add(job)
        redis.lrange("example", 0, -1).count { |raw| JSON.parse(raw.to_s)["jid"] == job.jid.to_s }.should eq(2)
      end
    end

    describe "D. sealed payloads" do
      before_each do
        JoobQ.config.payload_keys = nil
        JoobQ.config.payload_encryption AUDIT_KEY_A
      end

      after_each { JoobQ.config.payload_keys = nil }

      it "is AES-256-GCM: a 12-byte random nonce, ciphertext as long as the plain text, a 16-byte tag" do
        sealed = Encryption.seal("0123456789", "Job", "f")
        sealed.should start_with("jqe1:a1:")
        audit_raw(sealed).size.should eq(12 + 10 + 16)
        nonces = Array.new(50) { audit_raw(Encryption.seal("0123456789", "Job", "f"))[0, 12].hexstring }
        nonces.uniq.size.should eq(50)
        Encryption.open(Encryption.seal("", "Job", "f"), "Job", "f").should eq("")
      end

      it "refuses a changed nonce, ciphertext or tag, and a truncated tag" do
        sealed = Encryption.seal("0123456789", "Job", "f")
        {0, 12, 12 + 10, 12 + 10 + 15}.each do |index|
          changed = audit_reseal(sealed) { |raw| raw[index] = raw[index] ^ 0x01_u8 }
          expect_raises(Encryption::Error, /could not be opened/) { Encryption.open(changed, "Job", "f") }
        end
        raw = audit_raw(sealed)
        short = "#{sealed.rpartition(':')[0]}:#{Base64.urlsafe_encode(raw[0, raw.size - 4], padding: false)}"
        expect_raises(Encryption::Error) { Encryption.open(short, "Job", "f") }
      end

      it "refuses a wrong key under the same id, and a value relabelled with another configured key's id" do
        sealed = Encryption.seal("v", "Job", "f")
        JoobQ.config.payload_encryption "a1:" + "44" * 32
        expect_raises(Encryption::Error, /could not be opened/) { Encryption.open(sealed, "Job", "f") }

        JoobQ.config.payload_encryption AUDIT_KEY_C, [AUDIT_KEY_A]
        relabelled = sealed.sub("jqe1:a1:", "jqe1:c3:")
        expect_raises(Encryption::Error, /could not be opened/) { Encryption.open(relabelled, "Job", "f") }
        Encryption.open(sealed, "Job", "f").should eq("v")
      end

      it "does not bind a sealed value to its job id: it can be copied into another job of the same class" do
        first = AuditSealedJob.new("tok_first_12345")
        second = AuditSealedJob.new("tok_second_6789")
        sealed = JSON.parse(first.to_json)["token"].as_s
        forged = JSON.parse(second.to_json).as_h
        forged["token"] = JSON::Any.new(sealed)

        copy = AuditSealedJob.from_json(forged.to_json)
        copy.jid.should eq(second.jid)
        copy.token.should eq("tok_first_12345")
      end
    end

    describe "Delivery runtime" do
      it "redelivers a job whose execution outlived its execution timeout while the first execution still runs; only settlement is fenced" do
        runtime = Delivery::Runtime.new(RedisStore.instance, "audit-#{UUID.random}", capacity: 1,
          lease: 300.milliseconds, execution_timeout: 100.milliseconds, poll: 5.milliseconds, repair_every: 20.milliseconds)
        entered = Channel(Nil).new(1)
        release = Channel(Nil).new(1)
        inside = Atomic(Bool).new(false)
        ledger = runtime.register("work") do |_, _|
          inside.set(true)
          entered.send(nil)
          release.receive
          inside.set(false)
          Delivery::Outcome.new
        end
        runtime.admit("work", "id", "payload")
        runtime.start
        select
        when entered.receive
        when timeout(5.seconds)
          raise "handler did not enter"
        end

        competitor = nil
        eventually { (competitor = ledger.claim("competitor")) != nil }.should be_true
        inside.get.should be_true # the first execution is still running
        claim = competitor.not_nil!
        claim.attempt.should eq(2)

        release.send(nil)
        eventually { runtime.active_count == 0 }.should be_true
        ledger.settle(claim).should eq(Delivery::Settlement::Applied)
      ensure
        release.try(&.send(nil)) if runtime && runtime.active_count > 0
        runtime.try(&.stop(2.seconds))
      end
    end
  end
end
