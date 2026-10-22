require "./spec_helper"

module JoobQ
  describe DeadLetterQueue do
    redis = -> { JoobQ.store.as(RedisStore).redis }
    dlq = DeadLetterQueue.new(JoobQ.store.as(RedisStore).redis)

    # Seeds a dead job; scores order the entries (higher = newer).
    seed = ->(n : Int32, queue : String, score : Int64) do
      job = ExampleJob.new(n)
      job.queue = queue
      job.retries = 0
      job.dead!
      redis.call.zadd(DeadLetterQueue::KEY, score, job.to_json)
      job.jid.to_s
    end

    it "pages newest first and counts" do
      old = seed.call(1, "example", 1000_i64)
      new = seed.call(2, "example", 2000_i64)

      dlq.count.should eq(2)
      dlq.page(limit: 10).map(&.jid).should eq([new, old])
      dlq.page(offset: 1, limit: 1).map(&.jid).should eq([old])
    end

    it "filters by queue" do
      seed.call(1, "example", 1000_i64)
      other = seed.call(2, "test", 2000_i64)

      dlq.page(queue: "test").map(&.jid).should eq([other])
      dlq.count("test").should eq(1)
    end

    it "redrives an entry as a fresh enqueued job" do
      jid = seed.call(1, "example", 1000_i64)

      outcome = dlq.redrive([jid, "missing-jid"])

      outcome.succeeded.should eq(1)
      outcome.missing.should eq(["missing-jid"])
      dlq.count.should eq(0)
      pushed = JSON.parse(redis.call.lrange("example", 0, -1).first.to_s)
      pushed["jid"].as_s.should eq(jid)
      pushed["status"].as_s.should eq("enqueued")
      pushed["retries"].as_i.should eq(pushed["max_retries"].as_i)
      pushed["error"].raw.should be_nil
    end

    it "redrives an entry at most once under concurrent operators" do
      jid = seed.call(1, "example", 1000_i64)
      results = Channel(Int32).new(8)

      8.times do
        spawn do
          results.send(DeadLetterQueue.new(redis.call).redrive([jid]).succeeded)
        rescue ex
          results.send(-100) # a crash must fail the example, not hang it
        end
      end

      8.times.sum { results.receive }.should eq(1)
      redis.call.llen("example").should eq(1)
    end

    it "purges selected entries and all entries of a queue" do
      keep = seed.call(1, "example", 1000_i64)
      drop = seed.call(2, "example", 2000_i64)
      seed.call(3, "test", 3000_i64)

      dlq.purge([drop]).succeeded.should eq(1)
      dlq.find(drop).should be_nil
      dlq.find(keep).should_not be_nil

      dlq.purge_all("test").should eq(1)
      dlq.count.should eq(1)
    end

    it "refuses to redrive stubs of unparseable jobs" do
      stub = {jid: "stub-1", queue: "example", status: "Dead", original_job_data: "{broken"}.to_json
      redis.call.zadd(DeadLetterQueue::KEY, 1000_i64, stub)

      outcome = dlq.redrive(["stub-1"])

      outcome.succeeded.should eq(0)
      outcome.unredrivable.should eq(["stub-1"])
      dlq.count.should eq(1)
      redis.call.llen("example").should eq(0)
    end

    it "reaches entries beyond any scan chunk" do
      oldest = seed.call(0, "example", 1_i64)
      (1..450).each { |i| seed.call(i, "test", 1000_i64 + i) }

      dlq.count.should eq(451)
      dlq.find(oldest).should_not be_nil
      dlq.page(offset: 440, limit: 20, queue: "test").size.should eq(10)
    end

    it "clamps negative paging arguments" do
      seed.call(1, "example", 1000_i64)
      dlq.page(offset: -5, limit: -1).should be_empty
      dlq.page(offset: -5, limit: 5).size.should eq(1)
    end

    it "gives a redriven job a fresh expiry" do
      job = ExampleJob.new(1)
      job.expires = (Time.utc - 10.days).to_unix_ms
      job.dead!
      redis.call.zadd(DeadLetterQueue::KEY, 1000_i64, job.to_json)

      dlq.redrive([job.jid.to_s])

      pushed = JSON.parse(redis.call.lrange("example", 0, -1).first.to_s)
      pushed["expires"].as_i64.should be > Time.utc.to_unix_ms
    end

    it "scores jobs marked dead by time of death, like every other writer" do
      JoobQ.store.mark_as_dead(ExampleJob.new(1), 604_800_i64)

      dlq.page.first.failed_at.should be > 1_000_000_000_000_i64
    end

    it "purges a whole queue in slices" do
      (1..450).each { |i| seed.call(i, "test", 1000_i64 + i) }
      keep = seed.call(0, "example", 5_i64)

      dlq.purge_all("test").should eq(450)
      dlq.count.should eq(1)
      dlq.find(keep).should_not be_nil
    end
  end
end
