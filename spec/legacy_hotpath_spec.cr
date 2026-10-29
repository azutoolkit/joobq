require "./spec_helper"

class HotpathJob
  include JoobQ::Job
  getter index : Int32
  getter payload : String

  def initialize(@index, @payload = "", @queue = "hotpath")
    @expires = 1.hour.from_now.to_unix_ms
  end

  def perform
  end
end

module JoobQ
  describe "legacy hot path regressions" do
    it "streams nested values, escaped routing and exact numeric spellings" do
      raw = %q({"queue":"a\"b\\c\u2603","status":"Scheduled","nested":{"queue":"untouched","status":"Running","values":[null,true,9223372036854775807,0.123456789012345678901234567890,1.2300e+25]},"text":"line\n\"quoted\""})
      destination, encoded = SerializedJob.for_enqueue(raw)
      destination.should eq("a\"b\\c☃")
      SerializedJob.queue_name(raw).should eq(destination)
      result = JSON.parse(encoded)
      result["status"].as_s.should eq("Enqueued")
      result["nested"].should eq(JSON.parse(raw)["nested"])
      result["text"].as_s.should eq("line\n\"quoted\"")
      encoded.should contain("9223372036854775807")
      encoded.should contain("0.123456789012345678901234567890")
      encoded.should contain("1.2300e+25")
    end

    it "uses the last root queue and replaces every root status" do
      raw = %({"queue":42,"status":{},"queue":"hotpath","status":"Scheduled"})
      SerializedJob.queue_name(raw).should eq("hotpath")
      destination, encoded = SerializedJob.for_enqueue(raw)
      destination.should eq("hotpath")
      encoded.should eq(%({"queue":"hotpath","status":"Enqueued"}))
      expect_raises(ArgumentError) { SerializedJob.for_enqueue(%({"queue":"hotpath","queue":null})) }
      expect_raises(ArgumentError) { SerializedJob.queue_name(%({"queue":"hotpath","queue":null})) }
    end

    it "validates the entire document, including fields after queue" do
      [%({"queue":"hotpath","x":[}), %({"queue":"hotpath"} {}), %([])].each do |raw|
        expect_raises(JSON::Error) { SerializedJob.for_enqueue(raw) }
        expect_raises(JSON::Error) { SerializedJob.queue_name(raw) }
      end
      expect_raises(ArgumentError) { SerializedJob.for_enqueue(%({"nested":{"queue":"hotpath"}})) }
    end

    it "retains malformed scheduled records without partially promoting them" do
      store = JoobQ.store.as(RedisStore)
      raws = [%({"queue":"hotpath","x":[}), %({"queue":"hotpath"} {}), %({"queue":false})]
      raws.each { |raw| store.schedule_job(raw, 0_i64) }
      store.promote_due_jobs.should be_empty
      store.redis.zcard(RedisStore::DELAYED_SET).should eq(raws.size)
      store.redis.llen("hotpath").should eq(0)
    end

    it "reloads promotion scripts after cache flush and retains source on destination failure" do
      store = JoobQ.store.as(RedisStore)
      2.times do |index|
        raw = %({"queue":"hotpath","index":#{index}})
        store.schedule_job(raw, 0_i64)
        store.redis.command(["SCRIPT", "FLUSH"])
        store.promote_due_jobs.should eq([raw])
      end
      store.redis.llen("hotpath").should eq(2)
      bad = %({"queue":"wrong-type"})
      store.redis.set("wrong-type", "value")
      store.schedule_job(bad, 0_i64)
      store.promote_due_jobs.should be_empty
      store.redis.zscore(RedisStore::DELAYED_SET, bad).should_not be_nil
    end

    it "preserves queue filtering and the legacy scanned-record return contract" do
      store = JoobQ.store.as(RedisStore)
      other = %({"queue":"other","index":0})
      mine = %({"queue":"hotpath","index":1})
      store.schedule_job(other, 0_i64)
      store.schedule_job(mine, 1_i64)
      store.process_due_delayed_jobs("hotpath").should eq([other, mine])
      store.redis.llen("other").should eq(0)
      store.redis.llen("hotpath").should eq(1)
      store.redis.zscore(RedisStore::DELAYED_SET, other).should_not be_nil
    end

    it "honors queue pagination instead of fetching the default 200 jobs" do
      store = JoobQ.store.as(RedisStore)
      queue = Queue(HotpathJob).new("hotpath", 0)
      8.times { |i| store.redis.rpush("hotpath", i.to_s) }
      queue.jobs(2, 3).should eq(["3", "4", "5"])
      queue.jobs(4, 3).should be_empty
    end

    it "uses size hints only for capacity and rejects invalid hints before writing" do
      store = JoobQ.store.as(RedisStore)
      jobs = Array.new(5) { |i| HotpathJob.new(i, ("☃\n\"\\" * (i + 1))) }
      expect_raises(ArgumentError) { store.enqueue_batch(jobs, 2, json_sizes: [1]) }
      expect_raises(ArgumentError) { store.enqueue_batch(jobs, 2, json_sizes: [1, 1, 1, 1, -1]) }
      store.redis.llen("hotpath").should eq(0)
      store.enqueue_batch(jobs, 2, json_sizes: [0, 1, 4096, 2, 3])
      stored = store.list_jobs("hotpath").map { |raw| HotpathJob.from_json(raw) }
      stored.map(&.index).should eq(jobs.map(&.index))
      stored.map(&.payload).should eq(jobs.map(&.payload))
    end

    it "keeps unreadable batch members and serializes readable members through their typed model" do
      queue = Queue(HotpathJob).new("hotpath", 0)
      good = HotpathJob.new(1, "☃\n\"\\" * 300)
      raw = good.to_json.sub(/}$/, ",\"unmapped\":true}")
      queue.add_batch_strings(["unreadable", raw])
      stored = queue.jobs
      stored.size.should eq(2)
      HotpathJob.from_json(stored[0]).payload.should eq(good.payload)
      stored[0].should_not contain("unmapped")
      stored[1].should eq("unreadable")
    end

    it "captures each claim across multiple slices and drains all local tracking" do
      prior = JoobQ.config.worker_batch_size
      JoobQ.config.worker_batch_size = 97
      received = Channel(Int32).new(97)
      queue = Queue(HotpathJob).new("hotpath", 1, handler: ->(job : HotpathJob) { received.send(job.index); nil })
      queue.add_batch(Array.new(97) { |i| HotpathJob.new(i) })
      worker = Worker(HotpathJob).new(1, Channel(Nil).new(1), queue)
      worker.run
      seen = [] of Int32
      97.times do
        select
        when index = received.receive
          seen << index
        when timeout(5.seconds)
          fail "worker lost a claim"
        end
      end
      seen.sort.should eq((0...97).to_a)
      eventually { worker.in_progress == 0 && InFlight.count == 0 }.should be_true
      JoobQ.store.processing_queue_size("hotpath").should eq(0)
    ensure
      worker.try(&.terminate)
      JoobQ.config.worker_batch_size = prior || 10
    end
  end
end
