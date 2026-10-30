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

    it "redrives only the exact reviewed member and refuses a changed digest" do
      jid = seed.call(1, "example", 1000_i64)
      member = dlq.find(jid).not_nil!.member
      dlq.redrive_reviewed(jid, "stale").conflicted.should eq([jid])
      dlq.find(jid).should_not be_nil
      dlq.redrive_reviewed(jid, Digest::SHA256.hexdigest(member)).succeeded.should eq(1)
      dlq.find(jid).should be_nil
      dlq.redrive_reviewed(jid, Digest::SHA256.hexdigest(member)).missing.should eq([jid])
    end

    it "changes queue pause state only when it still matches the review" do
      store = JoobQ.store.as(RedisStore)
      store.set_paused("reviewed", false)
      store.set_paused_reviewed("reviewed", false, true).should be_true
      store.set_paused_reviewed("reviewed", false, false).should be_false
      store.paused?("reviewed").should be_true
      store.set_paused_reviewed("reviewed", true, false).should be_true
    end

    it "pages newest first and counts" do
      old = seed.call(1, "example", 1000_i64)
      new = seed.call(2, "example", 2000_i64)

      dlq.count.should eq(2)
      dlq.page(limit: 10).map(&.jid).should eq([new, old])
      dlq.page(offset: 1, limit: 1).map(&.jid).should eq([old])
    end

    describe "counts per queue" do
      held = -> { redis.call.hgetall(DeadLetterQueue::COUNTS).to_h { |q, c| {q.to_s, c.to_s.to_i64} } }

      it "are kept by the writers, so reading them never scans the set" do
        job = ExampleJob.new(1)
        job.queue = "example"
        JoobQ.store.as(RedisStore).move_to_dead_letter(job, "example")

        held.call.should eq({"example" => 1_i64})
        dlq.counts.should eq({"example" => 1_i64})
        dlq.count("example").should eq(1)
        dlq.count("other").should eq(0)
      end

      it "are trusted while they add up, so reading them does not scan the set" do
        seed.call(1, "example", 1000_i64)
        seed.call(2, "other", 2000_i64)
        dlq.counts
        redis.call.hset(DeadLetterQueue::COUNTS, "example", 0)
        redis.call.hset(DeadLetterQueue::COUNTS, "other", 0)
        redis.call.hset(DeadLetterQueue::COUNTS, "marker", 2) # adds up to the set, but a rescan would never say this

        dlq.counts.should eq({"marker" => 2_i64})
      end

      it "come from the entry's own queue, whatever name the caller moved it under" do
        job = ExampleJob.new(1)
        job.queue = "example"
        JoobQ.store.as(RedisStore).move_to_dead_letter(job, "aliased")

        dlq.counts.should eq({"example" => 1_i64})
        dlq.page(queue: "example").size.should eq(1)
        dlq.purge([job.jid.to_s]).succeeded.should eq(1)
        dlq.counts.should be_empty
      end

      it "count a member once however often it is written" do
        job = ExampleJob.new(1)
        job.queue = "example"
        store = JoobQ.store.as(RedisStore)
        store.mark_as_dead(job, 0_i64)
        store.mark_as_dead(job, 0_i64)

        dlq.counts.should eq({"example" => 1_i64})
        held.call.should eq({"example" => 1_i64})
      end

      it "stay exact next to members that are not jobs, without rescanning" do
        seed.call(1, "example", 1000_i64)
        DeadLetterQueue.add(redis.call, 2000_i64, ["not json"]).should eq(1)

        dlq.counts.should eq({"example" => 1_i64})
        held.call.should eq({"example" => 1_i64, DeadLetterQueue::UNKNOWN => 1_i64})
      end

      it "follow redrives and purges" do
        a = seed.call(1, "example", 1000_i64)
        b = seed.call(2, "example", 2000_i64)
        seed.call(3, "other", 3000_i64)
        dlq.counts # entries seeded without a writer are counted on first read

        dlq.redrive([a]).succeeded.should eq(1)
        dlq.purge([b]).succeeded.should eq(1)

        held.call.reject { |_, n| n == 0 }.should eq({"other" => 1_i64})
        dlq.counts.should eq({"other" => 1_i64})
        dlq.purge_all("other")
        dlq.counts.should be_empty
      end

      it "are rebuilt when they no longer add up to the set" do
        seed.call(1, "example", 1000_i64)
        seed.call(2, "example", 2000_i64)
        redis.call.hset(DeadLetterQueue::COUNTS, "example", 7) # drifted

        dlq.counts.should eq({"example" => 2_i64})
        held.call.should eq({"example" => 2_i64})
      end
    end

    it "keeps an entry whose queue name is not a queue, instead of losing it" do
      # a key of another type: pushing onto it fails, and a script that already removed the entry would lose it
      jid = seed.call(1, DeadLetterQueue::KEY, 1000_i64)

      outcome = dlq.redrive([jid])

      outcome.succeeded.should eq(0)
      outcome.unredrivable.should eq([jid])
      dlq.find(jid).should_not be_nil
      dlq.count.should eq(1)
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
