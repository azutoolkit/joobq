require "./spec_helper"

KEY_A = "a1:" + "11" * 32
KEY_B = "b2:" + "22" * 32

SECRET_TOKEN = "tok_live_9f8e7d6c5b4a"
SECRET_NOTE  = "the-sealed-note-xyz"

class SecretJob
  include JoobQ::Job

  @queue = "secrets"
  @retries = 0

  class_property performed = [] of String
  class_property mode = "ok"

  property order_id : Int32 = 0
  encrypted_property token : String = ""
  encrypted_property note : String? = nil
  encrypted_property meta : Hash(String, Int32)? = nil

  def initialize
  end

  def initialize(@order_id : Int32, @token : String, @note : String? = nil, @meta : Hash(String, Int32)? = nil)
  end

  def perform
    SecretJob.performed << token
    raise "gateway rejected #{token}" if SecretJob.mode == "fail"
  end
end

class SubSecretJob < SecretJob
  encrypted_property extra : String = ""
end

# Every value Redis holds, as text, whatever the key's type.
def redis_dump(redis) : String
  String.build do |io|
    redis.keys("*").each do |key|
      key = key.to_s
      case redis.type(key)
      when "list"   then redis.lrange(key, 0, -1).each { |v| io << v.to_s << '\n' }
      when "zset"   then redis.zrange(key, 0, -1).each { |v| io << v.to_s << '\n' }
      when "hash"   then redis.hgetall(key).each { |v| io << v.to_s << '\n' }
      when "set"    then redis.smembers(key).each { |v| io << v.to_s << '\n' }
      when "string" then io << redis.get(key).to_s << '\n'
      when "stream" then io << redis.command(["XRANGE", key, "-", "+"]).inspect << '\n'
      end
    end
  end
end

module JoobQ
  describe Encryption do
    before_each do
      JoobQ.config.payload_keys = nil
      JoobQ.config.allow_plaintext_payloads = true
      JoobQ.config.payload_encryption KEY_A
      SecretJob.performed.clear
      SecretJob.mode = "ok"
    end

    after_each do
      JoobQ.config.payload_keys = nil
    end

    describe "sealing" do
      it "round trips and is bound to the class and the field" do
        sealed = Encryption.seal("hello", "Job", "f")
        sealed.should start_with("jqe1:a1:")
        sealed.should_not contain("hello")
        Encryption.open(sealed, "Job", "f").should eq "hello"
        Encryption.seal("hello", "Job", "f").should_not eq sealed # fresh nonce

        expect_raises(Encryption::Error, /could not be opened/) { Encryption.open(sealed, "Job", "other") }
        expect_raises(Encryption::Error, /could not be opened/) { Encryption.open(sealed, "Other", "f") }
      end

      it "refuses an altered value" do
        sealed = Encryption.seal("hello", "Job", "f")
        altered = sealed[0..-3] + (sealed[-1] == 'A' ? "BB" : "AA")
        expect_raises(Encryption::Error) { Encryption.open(altered, "Job", "f") }
        expect_raises(Encryption::Error, /damaged/) { Encryption.open("jqe1:a1:abc", "Job", "f") }
      end

      it "rotates: the first key seals, every key opens" do
        old = Encryption.seal("v", "Job", "f")
        JoobQ.config.payload_encryption KEY_B, [KEY_A]
        fresh = Encryption.seal("v", "Job", "f")

        fresh.should start_with("jqe1:b2:")
        Encryption.open(old, "Job", "f").should eq "v"
        Encryption.open(fresh, "Job", "f").should eq "v"

        JoobQ.config.payload_encryption KEY_B
        expect_raises(Encryption::Error, /key "a1", which is not configured/) { Encryption.open(old, "Job", "f") }
      end

      it "reads keys from the environment when none are configured" do
        JoobQ.config.payload_keys = nil
        ENV["JOOBQ_PAYLOAD_KEYS"] = "#{KEY_B},#{KEY_A}"
        Encryption.reset_env_keys
        begin
          Encryption.keys.current_id.should eq "b2"
          Encryption.keys.ids.sort!.should eq %w(a1 b2)
        ensure
          ENV.delete("JOOBQ_PAYLOAD_KEYS")
          Encryption.reset_env_keys
        end

        ENV["JOOBQ_PAYLOAD_KEY"] = Base64.strict_encode(Bytes.new(32, 7_u8))
        Encryption.reset_env_keys
        begin
          Encryption.keys.current_id.should eq "default"
        ensure
          ENV.delete("JOOBQ_PAYLOAD_KEY")
          Encryption.reset_env_keys
        end
      end

      it "fails clearly without a key, and never prints a key" do
        JoobQ.config.payload_keys = nil
        Encryption.reset_env_keys
        expect_raises(Encryption::Error, /no payload encryption key/) { Encryption.seal("x", "J", "f") }
        error = expect_raises(Encryption::Error) { JoobQ.config.payload_encryption "bad:" + "zz" * 5 }
        error.message.to_s.should_not contain("zz")
        expect_raises(Encryption::Error, /must be 32 bytes/) { JoobQ.config.payload_encryption "k:" + "ab" * 8 }
        expect_raises(Encryption::Error, /appears twice/) { JoobQ.config.payload_encryption KEY_A, [KEY_A] }
      end
    end

    describe "a job with encrypted properties" do
      it "writes no plain value and reads them back" do
        job = SecretJob.new(7, SECRET_TOKEN, SECRET_NOTE, {"n" => 3})
        json = job.to_json
        json.should_not contain(SECRET_TOKEN)
        json.should_not contain(SECRET_NOTE)
        json.should contain("\"order_id\":7")

        back = SecretJob.from_json(json)
        back.token.should eq SECRET_TOKEN
        back.note.should eq SECRET_NOTE
        back.meta.should eq({"n" => 3})
        back.order_id.should eq 7
        back.__secret_values.should contain(SECRET_TOKEN)
      end

      it "does not write a nil property" do
        json = SecretJob.new(1, "abcd").to_json
        json.should_not contain("\"note\"")
        SecretJob.from_json(json).note.should be_nil
      end

      it "reads a payload written before encryption, and can refuse it" do
        plain = %({"jid":"#{UUID.random}","queue":"secrets","retries":0,"max_retries":0,"expires":#{Time.utc.to_unix_ms + 100000},"status":"Enqueued","order_id":1,"token":"#{SECRET_TOKEN}","note":"n","meta":{"a":1}})
        old = SecretJob.from_json(plain)
        old.token.should eq SECRET_TOKEN
        old.meta.should eq({"a" => 1})
        old.to_json.should_not contain(SECRET_TOKEN)

        JoobQ.config.allow_plaintext_payloads = false
        expect_raises(Encryption::Error, /not encrypted/) { Encryption.strict { SecretJob.from_json(plain) } }
      end

      it "refuses a value sealed for another field" do
        job = SecretJob.new(1, SECRET_TOKEN, "note-value")
        data = JSON.parse(job.to_json).as_h
        data["token"] = data["note"]
        expect_raises(Encryption::Error) { SecretJob.from_json(data.to_json) }
      end

      it "raises to the caller when enqueued without a key" do
        JoobQ.config.payload_keys = nil
        Encryption.reset_env_keys
        expect_raises(Encryption::Error, /no payload encryption key/) { SecretJob.new(1, SECRET_TOKEN).to_json }
      end

      it "applies allow_plaintext_payloads = false to the worker path only" do
        plain = %({"jid":"#{UUID.random}","queue":"secrets","retries":0,"max_retries":0,"expires":#{Time.utc.to_unix_ms + 100000},"status":"Enqueued","order_id":1,"token":"plain-token"})
        JoobQ.config.allow_plaintext_payloads = false
        SecretJob.from_json(plain).token.should eq "plain-token" # Queue#add, the API
        expect_raises(Encryption::Error, /not encrypted/) { Encryption.strict { SecretJob.from_json(plain) } }
        Encryption.strict?.should be_false
      end

      it "works in a subclass, with its own encrypted properties" do
        job = SubSecretJob.new
        job.token = SECRET_TOKEN
        job.extra = "sub-extra-value"
        json = job.to_json
        json.should_not contain(SECRET_TOKEN)
        json.should_not contain("sub-extra-value")
        back = SubSecretJob.from_json(json)
        back.token.should eq SECRET_TOKEN
        back.extra.should eq "sub-extra-value"
        back.__secret_values.should contain("sub-extra-value")
        back.__secret_values.should contain(SECRET_TOKEN)
      end

      it "scrubs every form of a non-string value, longest first" do
        job = SecretJob.new(1, "abcd", nil, {"pin" => 424242, "n" => 3})
        forms = job.__secret_values
        forms.should contain("424242")
        forms.should contain({"pin" => 424242, "n" => 3}.to_s)
        forms.should contain(%({"pin":424242,"n":3}))
        forms.map(&.size).should eq forms.map(&.size).sort.reverse!
        ex = %(rejected {"pin":424242,"n":3} and 424242)
        Encryption.scrub(ex, forms).should_not contain("424242")
      end

      it "scrubs plain values from errors the library records" do
        queue = Queue(SecretJob).new("secrets", 1)
        job = SecretJob.new(1, SECRET_TOKEN)
        ex = Exception.new("gateway rejected #{SECRET_TOKEN}", cause: Exception.new("cause #{SECRET_TOKEN}"))
        context = ErrorContext.from_exception(job, queue, ex, "w1")
        [context.error_message, context.error_cause.to_s, context.backtrace.join, context.job_data.to_s].each do |text|
          text.should_not contain(SECRET_TOKEN)
        end
        context.error_message.should eq "gateway rejected [REDACTED]"
      end
    end

    describe "end to end through Redis" do
      redis = JoobQ.store.as(RedisStore).redis

      it "stores ciphertext everywhere and performs with plain values" do
        JoobQ.reset
        queue = Queue(SecretJob).new("secrets", 1)
        done = Channel(Nil).new
        worker = Worker(SecretJob).new(1, done, queue)

        JoobQ.add SecretJob.new(1, SECRET_TOKEN, SECRET_NOTE)
        redis_dump(redis).should_not contain(SECRET_TOKEN)
        redis_dump(redis).should contain("jqe1:a1:")

        worker.run
        eventually { SecretJob.performed.size == 1 }.should be_true
        SecretJob.performed.should eq [SECRET_TOKEN]
        worker.terminate
        redis_dump(redis).should_not contain(SECRET_TOKEN)
        redis_dump(redis).should_not contain(SECRET_NOTE)
      end

      it "leaves no plain value in Redis when a job fails (dead letter, error, events)" do
        JoobQ.reset
        SecretJob.mode = "fail"
        queue = Queue(SecretJob).new("secrets", 1)
        done = Channel(Nil).new
        worker = Worker(SecretJob).new(1, done, queue)

        JoobQ.add SecretJob.new(1, SECRET_TOKEN)
        worker.run
        eventually { SecretJob.performed.size == 1 && DeadLetterQueue.new(redis).count == 1 }.should be_true
        worker.terminate

        dump = redis_dump(redis)
        dump.should contain("gateway rejected [REDACTED]")
        dump.should_not contain(SECRET_TOKEN)
      end

      it "dead-letters a job whose key is gone, as the job itself, and redrives it when the key is back" do
        JoobQ.reset
        job = SecretJob.new(1, SECRET_TOKEN)
        JoobQ.add job

        JoobQ.config.payload_encryption KEY_B # the key that sealed the job is gone
        queue = Queue(SecretJob).new("secrets", 1)
        done = Channel(Nil).new
        worker = Worker(SecretJob).new(1, done, queue)
        worker.run
        dlq = DeadLetterQueue.new(redis)
        eventually { dlq.count == 1 }.should be_true
        worker.terminate

        SecretJob.performed.should be_empty
        entry = dlq.page(limit: 1).first
        entry.error.to_s.should contain("could not be decrypted")
        entry.error.to_s.should contain("key \"a1\"")
        entry.redrivable?.should be_true
        redis_dump(redis).should_not contain(SECRET_TOKEN)
        redis_dump(redis).should contain("jqe1:a1:")

        JoobQ.config.payload_encryption KEY_B, [KEY_A] # the key is back
        dlq.redrive([entry.jid]).succeeded.should eq 1
        worker = Worker(SecretJob).new(2, done, queue)
        worker.run
        eventually { SecretJob.performed.size == 1 }.should be_true
        worker.terminate
        SecretJob.performed.should eq [SECRET_TOKEN]
      end

      it "leaves a job in its queue, not the dead letter set, when the process has no keys" do
        JoobQ.reset
        JoobQ.add SecretJob.new(1, SECRET_TOKEN)
        JoobQ.config.payload_keys = nil
        Encryption.reset_env_keys
        Encryption.key_backoff = 50.milliseconds
        begin
          queue = Queue(SecretJob).new("secrets", 1)
          done = Channel(Nil).new
          worker = Worker(SecretJob).new(1, done, queue)
          worker.run
          sleep 300.milliseconds
          worker.terminate
          sleep 200.milliseconds

          SecretJob.performed.should be_empty
          DeadLetterQueue.new(redis).count.should eq 0
          (redis.llen("secrets") + JoobQ.store.processing_queue_size("secrets")).should eq 1
          redis_dump(redis).should contain("jqe1:a1:")
        ensure
          Encryption.key_backoff = 5.seconds
        end
        # with the key back, the same job runs
        JoobQ.config.payload_encryption KEY_A
        worker = Worker(SecretJob).new(3, Channel(Nil).new, Queue(SecretJob).new("secrets", 1))
        worker.run
        eventually { SecretJob.performed.size == 1 }.should be_true
        worker.terminate
      end

      it "refuses to start a queue of encrypted jobs without keys" do
        JoobQ.config.payload_keys = nil
        Encryption.reset_env_keys
        expect_raises(Encryption::ConfigurationError) { Queue(SecretJob).new("secrets", 1).start }
        ENV["JOOBQ_PAYLOAD_KEYS"] = "not-a-key"
        Encryption.reset_env_keys
        begin
          expect_raises(Encryption::ConfigurationError, /neither 64 hex digits nor base64|bytes/) { Queue(SecretJob).new("secrets", 1).start }
        ensure
          ENV.delete("JOOBQ_PAYLOAD_KEYS")
          Encryption.reset_env_keys
        end
      end

      it "keeps ciphertext in the retry set and runs the job later with plain values" do
        JoobQ.reset
        SecretJob.mode = "fail"
        queue = Queue(SecretJob).new("secrets", 1)
        done = Channel(Nil).new
        worker = Worker(SecretJob).new(1, done, queue)
        job = SecretJob.new(1, SECRET_TOKEN)
        job.retries = 2
        job.max_retries = 2
        JoobQ.add job
        worker.run
        eventually { redis.zcard(RedisStore::DELAYED_SET) >= 1 }.should be_true
        worker.terminate

        delayed = redis.zrange(RedisStore::DELAYED_SET, 0, -1).map(&.to_s).join
        delayed.should contain("jqe1:a1:")
        delayed.should_not contain(SECRET_TOKEN)
        redis_dump(redis).should_not contain(SECRET_TOKEN)

        SecretJob.mode = "ok"
        SecretJob.performed.clear
        JoobQ.config.schedulers.first.enqueue_due_jobs(current_time: 1.hour.from_now)
        worker = Worker(SecretJob).new(2, done, queue)
        worker.run
        eventually { SecretJob.performed.size >= 1 }.should be_true
        worker.terminate
        SecretJob.performed.uniq.should eq [SECRET_TOKEN]
      end

      it "loses nothing when a batch of due jobs holds one it cannot open" do
        JoobQ.reset
        bad = SecretJob.new(1, "other-secret-value").to_json # sealed with key a1
        JoobQ.config.payload_encryption KEY_B
        good = SecretJob.new(2, SECRET_TOKEN).to_json
        queue = Queue(SecretJob).new("secrets", 1)

        queue.add_batch_strings([bad, good])
        redis.llen("secrets").should eq 2

        redis.del("secrets")
        redis.zadd(RedisStore::DELAYED_SET, 1, bad)
        redis.zadd(RedisStore::DELAYED_SET, 2, good)
        JoobQ.config.schedulers.first.enqueue_due_jobs(current_time: 1.hour.from_now)
        redis.zcard(RedisStore::DELAYED_SET).should eq 0
        redis.llen("secrets").should eq 2
      end

      it "records no plain value in events" do
        JoobQ.reset
        SecretJob.mode = "fail"
        sink = CollectingSink.new
        Events.subscribe(sink)
        begin
          queue = Queue(SecretJob).new("secrets", 1)
          worker = Worker(SecretJob).new(1, Channel(Nil).new, queue)
          JoobQ.add SecretJob.new(1, SECRET_TOKEN)
          worker.run
          seen = [] of String
          spawn { loop { seen << sink.received.receive.to_json } }
          eventually { seen.any?(&.includes?("job.failed")) }.should be_true
          worker.terminate
          seen.join.should_not contain(SECRET_TOKEN)
          seen.join.should contain("gateway rejected [REDACTED]")
        ensure
          Events.unsubscribe(sink)
        end
      end

      it "reads a plain job that was queued before encryption" do
        JoobQ.reset
        plain = %({"jid":"#{UUID.random}","queue":"secrets","retries":0,"max_retries":0,"expires":#{Time.utc.to_unix_ms + 100000},"status":"Enqueued","order_id":1,"token":"legacy-plain-token","note":null,"meta":null})
        redis.rpush "secrets", plain

        queue = Queue(SecretJob).new("secrets", 1)
        done = Channel(Nil).new
        worker = Worker(SecretJob).new(1, done, queue)
        worker.run
        eventually { SecretJob.performed.size == 1 }.should be_true
        worker.terminate
        SecretJob.performed.should eq ["legacy-plain-token"]
      end
    end
  end
end
