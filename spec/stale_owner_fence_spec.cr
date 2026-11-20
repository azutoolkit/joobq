require "./spec_helper"

# A process frozen or partitioned past the heartbeat TTL is judged dead: recovery moves its processing list back to
# the queue and another process runs the jobs. When the old owner wakes up and finishes its copies, its settlement
# must be refused (the copy it would remove and count is gone), so each job is counted once.
class FenceJob
  include JoobQ::Job

  STARTED = Channel(Nil).new(8)
  RELEASE = Channel(Nil).new(8)

  property fail : Bool = false

  def initialize(queue : String = "fence_unused", @fail : Bool = false, retries : Int32 = 0)
    @queue = queue
    @retries = retries
    @max_retries = retries
  end

  def self.drain : Nil
    [STARTED, RELEASE].each do |channel|
      loop do
        select
        when channel.receive
        else
          break
        end
      end
    end
  end

  def perform
    STARTED.send(nil)
    select
    when RELEASE.receive
    when timeout(20.seconds)
    end
    raise "boom" if @fail
  end
end

# Specs only: an exception after the retry was stored, as a failing sink or log line would raise
module JoobQ::Events
  class_property spec_raise_on : String? = nil

  def self.emit(type : String, & : -> _) : Nil
    raise "boom after the write" if type == @@spec_raise_on
    previous_def { yield }
  end
end

module JoobQ
  describe "a stale owner" do
    store = JoobQ.store.as(RedisStore)
    redis = store.redis
    name = ""
    stale_id = "stale-host:7101"
    survivor = RedisStore.new
    survivor.owner_id = "survivor-host:7102"
    queue = nil.as(Queue(FenceJob)?)

    stat = ->(family : String) { redis.hget(Keys.stat(family), name).try(&.to_i64) || 0_i64 }
    # the heartbeat of `id` is older than the TTL, so recovery judges it dead
    lapse = ->(id : String) { redis.zadd(RedisStore::OWNERS, store.redis_now_ms - 120_000, id) }
    mentions = ->(set : String, jid : String) { redis.zrange(set, 0, -1).any? { |entry| entry.to_s.includes?(jid) } }

    before_each do
      name = "fence_#{Random::Secure.hex(3)}"
      InFlight.clear
      FenceJob.drain
    end

    after_each do
      queue.try(&.stop!)
      JoobQ.queues.delete(name)
      InFlight.clear
      redis.del(Keys.queue(name), Keys.processing(name, store.owner_id), Keys.processing(name, stale_id),
        Keys.processing(name, survivor.owner_id), Keys.paused(name))
      %w[processed completed retries dead_letter total_processed total_completed].each { |family| redis.hdel(Keys.stat(family), name) }
      redis.zrem(RedisStore::OWNERS, stale_id)
      redis.zrem(RedisStore::OWNERS, survivor.owner_id)
      redis.zrange(Keys::DEAD_LETTER, 0, -1).each { |entry| redis.zrem(Keys::DEAD_LETTER, entry) if entry.to_s.includes?(name) }
      redis.del(Keys::DEAD_LETTER_COUNTS)
      redis.zremrangebyscore(RedisStore::DELAYED_SET, "-inf", "+inf")
    end

    # A claim of the stale process, as a worker holds it: in its own list and in `InFlight`, running in this fiber.
    claim_as_stale = -> do
      stale = RedisStore.new
      stale.owner_id = stale_id
      job = FenceJob.new(name, retries: 1)
      redis.rpush(Keys.queue(name), job.to_json)
      raw = stale.dequeue(name, FenceJob).not_nil!
      {stale, job, raw}
    end

    # The survivor's recovery after the stale process's heartbeat lapsed, then its own run of the job
    reclaim = ->(stale : RedisStore) do
      lapse.call(stale.owner_id)
      survivor.recover_orphaned_processing(name).should eq(1)
    end

    describe "settling a success" do
      it "is counted by the holder only: the survivor counts it, the stale owner's late settlement counts nothing" do
        stale, _, raw = claim_as_stale.call
        reclaim.call(stale)
        survivor.dequeue(name, FenceJob).should eq(raw)
        survivor.mark_job_completed(raw, name).should be_true
        stat.call("completed").should eq(1)

        stale.mark_job_completed(raw, name).should be_true # settled as far as it is concerned: nothing to retain
        stat.call("completed").should eq(1)
        stat.call("processed").should eq(1)
      end

      it "does not delete or count the job that is back on its queue and not claimed yet" do
        stale, _, raw = claim_as_stale.call
        reclaim.call(stale)

        stale.mark_job_completed(raw, name).should be_true
        stat.call("completed").should eq(0)
        stat.call("processed").should eq(0)
        redis.lrange(Keys.queue(name), 0, -1).should eq([raw]) # still there for the survivor
      end

      it "still counts a claim that is held (control)" do
        stale, _, raw = claim_as_stale.call
        stale.mark_job_completed(raw, name).should be_true
        stat.call("completed").should eq(1)
        redis.llen(Keys.processing(name, stale_id)).should eq(0)
      end

      it "refuses a late failure cleanup too (cleanup_job)" do
        stale, _, raw = claim_as_stale.call
        reclaim.call(stale)
        stale.cleanup_job(raw, name).should be_true
        stat.call("processed").should eq(0)
      end

      it "refuses a late batch cleanup too, and counts a held one (cleanup_jobs_batch)" do
        stale, _, raw = claim_as_stale.call
        second = FenceJob.new(name).to_json
        redis.rpush(Keys.queue(name), second)
        second = stale.dequeue(name, FenceJob).not_nil!
        stale.cleanup_jobs_batch([second], name)
        stat.call("processed").should eq(1)
        redis.llen(Keys.processing(name, stale_id)).should eq(1) # only the settled copy left the list

        reclaim.call(stale)
        stale.cleanup_jobs_batch([raw], name)
        stat.call("processed").should eq(1) # the reclaimed one counted nothing
      end

      it "logs a warning" do
        stale, _, raw = claim_as_stale.call
        reclaim.call(stale)
        logs = Log::MemoryBackend.new
        Log.builder.bind("*", :warn, logs)
        begin
          stale.mark_job_completed(raw, name)
        ensure
          Log.builder.unbind("*", :warn, logs)
        end
        logs.entries.count(&.message.includes?("reclaimed this job")).should eq(1)
      end
    end

    describe "settling a failure inside a worker" do
      claim_in_flight = ->(stale : RedisStore, raw : String) do
        token = InFlight.claimed(name, [raw]).first
        InFlight.begin_run(token).should be_true
        token
      end

      it "schedules no retry once the claim was reclaimed, and the execution becomes inert" do
        stale, job, raw = claim_as_stale.call
        reclaim.call(stale)
        claim_in_flight.call(stale, raw)

        job.retries = 0
        stale.move_to_retry(job, name, 1000_i64).should be_false
        mentions.call(RedisStore::DELAYED_SET, job.jid.to_s).should be_false
        stat.call("retries").should eq(0)
        InFlight.abandoned?.should be_true
      end

      it "schedules the retry of a claim it still holds, in one step (control)" do
        stale, job, raw = claim_as_stale.call
        token = claim_in_flight.call(stale, raw)

        stale.move_to_retry(job, name, 1000_i64).should be_true
        mentions.call(RedisStore::DELAYED_SET, job.jid.to_s).should be_true
        stat.call("retries").should eq(1)
        InFlight.abandoned?.should be_false
        redis.llen(Keys.processing(name, stale_id)).should eq(0) # the same step took the claim copy off the list
        stat.call("processed").should eq(1)
        stale.redrive_one(name, raw).should eq(0) # so there is nothing to re-drive if the worker's cleanup is lost
        InFlight.applied?(token).should be_true
      end

      it "still answers true, and keeps the claim applied, when an exception follows the stored retry" do
        stale, job, raw = claim_as_stale.call
        token = claim_in_flight.call(stale, raw)
        Events.spec_raise_on = "job.retrying"
        begin
          stale.move_to_retry(job, name, 1000_i64).should be_true # else the Retry middleware would try a dead letter
        ensure
          Events.spec_raise_on = nil
        end
        InFlight.applied?(token).should be_true
        stat.call("retries").should eq(1)
      end

      it "keeps the applied mark through settle, fence and abandon_all" do
        stale, _, raw = claim_as_stale.call
        token = claim_in_flight.call(stale, raw)
        InFlight.applied
        InFlight.settle.should be_true # the catch-all rescue settles again after the outcome was applied
        InFlight.applied?(token).should be_true
        InFlight.fence
        InFlight.applied?(token).should be_true
      end

      it "keeps the applied mark of a claim that shutdown abandons" do
        stale, _, raw = claim_as_stale.call
        token = claim_in_flight.call(stale, raw)
        InFlight.applied
        InFlight.abandon_all(settling: true)
        InFlight.applied?(token).should be_true
      end

      it "dead-letters nothing once the claim was reclaimed" do
        stale, job, raw = claim_as_stale.call
        reclaim.call(stale)
        claim_in_flight.call(stale, raw)

        job.dead!
        stale.move_to_dead_letter(job, name)
        mentions.call(Keys::DEAD_LETTER, job.jid.to_s).should be_false
        stat.call("dead_letter").should eq(0)
        InFlight.abandoned?.should be_true
      end

      it "dead-letters a claim it still holds (control)" do
        stale, job, raw = claim_as_stale.call
        claim_in_flight.call(stale, raw)

        job.dead!
        stale.move_to_dead_letter(job, name)
        mentions.call(Keys::DEAD_LETTER, job.jid.to_s).should be_true
        stat.call("dead_letter").should eq(1)
        stat.call("processed").should eq(1)
        redis.llen(Keys.processing(name, stale_id)).should eq(0)
        stale.redrive_one(name, raw).should eq(0)
      end

      it "writes no dead letter for an expired job whose claim was reclaimed (mark_as_dead)" do
        stale, job, raw = claim_as_stale.call
        reclaim.call(stale)
        claim_in_flight.call(stale, raw)

        stale.mark_as_dead(job, 0_i64)
        mentions.call(Keys::DEAD_LETTER, job.jid.to_s).should be_false
        InFlight.abandoned?.should be_true
      end
    end

    describe "an unparseable payload" do
      it "is dead-lettered while the claim is held, and not once it was reclaimed" do
        worker = Worker(ExampleJob).new(1, Channel(Nil).new(1), JoobQ.queues["example"])
        junk = "{\"jid\": \"unparseable-#{name}"
        [true, false].each do |reclaimed|
          before = redis.zcard(Keys::DEAD_LETTER)
          redis.rpush(Keys.processing("example", store.owner_id), junk) unless reclaimed # held: the copy is in the list
          token = InFlight.claimed("example", [junk]).first
          done = Channel(Nil).new
          spawn do
            InFlight.begin_run(token)
            worker.test_unparseable(junk, Exception.new("bad json"))
          ensure
            InFlight.finished(token)
            done.send(nil)
          end
          done.receive
          (redis.zcard(Keys::DEAD_LETTER) - before).should eq(reclaimed ? 0 : 1)
          redis.del(Keys.processing("example", store.owner_id))
        end
        redis.zremrangebyscore(Keys::DEAD_LETTER, "-inf", "+inf")
        redis.del(Keys::DEAD_LETTER_COUNTS)
      end
    end

    describe "the heartbeat pause" do
      it "never exceeds the beat period, even while retained copies wait to be re-driven" do
        short = RedisStore.new
        short.owner_ttl = 1.second
        InFlight.clear
        token = InFlight.claimed(name, ["x"]).first
        InFlight.begin_run(token)
        InFlight.finishing(token)
        InFlight.done(token, retain: true)
        short.heartbeat_pause.should be <= short.owner_beat
        InFlight.clear
        short.heartbeat_pause.should eq(short.owner_beat)
      end
    end

    describe "a heartbeat that lapsed" do
      it "is logged by the process's next beat" do
        stale = RedisStore.new
        stale.owner_id = stale_id
        stale.beat_owner # the first beat has no predecessor
        lapse.call(stale_id)
        logs = Log::MemoryBackend.new
        Log.builder.bind("*", :warn, logs)
        begin
          stale.beat_owner
        ensure
          Log.builder.unbind("*", :warn, logs)
        end
        logs.entries.count(&.message.includes?("heartbeat lapsed")).should eq(1)
        stale.beat_owner # healthy again: silent
      end
    end

    describe "a whole worker whose process was frozen past the TTL" do
      {false => "a job that succeeds", true => "a job that fails"}.each do |fails, title|
        it "counts #{title} once, schedules no retry and dead-letters nothing (#{title})" do
          typed = Queue(FenceJob).new(name, 1)
          queue = typed
          JoobQ.queues[name] = typed
          typed.start
          job = FenceJob.new(name, fail: fails, retries: 1)
          JoobQ.enqueue(name, job.to_json)
          select
          when FenceJob::STARTED.receive
          when timeout(10.seconds)
            fail "the job did not start"
          end

          # the process "freezes": no claims meanwhile, its heartbeat lapses, the survivor reclaims and runs the job
          typed.pause!
          sleep 700.milliseconds # the claim loop caches the pause flag for 500 ms
          lapse.call(store.owner_id)
          survivor.recover_orphaned_processing(name).should eq(1)
          raw = survivor.dequeue(name, FenceJob).not_nil!
          survivor.mark_job_completed(raw, name).should be_true
          stat.call("completed").should eq(1)

          # the process wakes and finishes its copy
          FenceJob::RELEASE.send(nil)
          eventually(10.seconds) { InFlight.count == 0 }.should be_true
          sleep 200.milliseconds

          stat.call("completed").should eq(1)
          stat.call("processed").should eq(1)
          stat.call("retries").should eq(0)
          stat.call("dead_letter").should eq(0)
          mentions.call(RedisStore::DELAYED_SET, job.jid.to_s).should be_false
          mentions.call(Keys::DEAD_LETTER, job.jid.to_s).should be_false
          JoobQ.processing_depth(redis, name).should eq(0)
        end
      end
    end
  end
end
