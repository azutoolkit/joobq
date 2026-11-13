require "./spec_helper"

# The dispatcher registers every claim in InFlight before a worker receives it. When `stop!` runs, a claim the
# dispatcher is still trying to deliver and the claims staged in its channel never reach a worker: their InFlight
# entries must be released (the jobs stay in the processing list), or `InFlight.any?` stays true and every later
# start in this process skips the recovery that would run them.
module JoobQ
  # Specs only (as in spec/shutdown_spec.cr): `JoobQ.shutdown` stops this process's queues for good.
  def self.spec_shut_down(value : Bool) : Nil
    @@shut_down.set(value)
  end

  class StopBufferedJob
    include JoobQ::Job

    # What ran, in order; `RELEASE` holds every "blocker" job inside `perform` until the example releases it.
    LOG     = [] of String
    LOCK    = Sync::Mutex.new
    RELEASE = Atomic(Bool).new(false)

    getter label : String

    def initialize(@label : String = "", queue : String = "stop_buffered_unused")
      @queue = queue
    end

    def perform
      LOCK.synchronize { LOG << @label }
      return unless @label == "blocker"
      until RELEASE.get
        sleep 5.milliseconds
      end
    end

    def self.runs(label : String) : Int32
      LOCK.synchronize { LOG.count(label) }
    end

    def self.reset : Nil
      LOCK.synchronize { LOG.clear }
      RELEASE.set(false)
    end
  end

  describe "stopping a Queue while the dispatcher holds claims no worker received" do
    store = JoobQ.store.as(RedisStore)
    redis = store.redis
    owned = ->(name : String) { "joobq:processing:#{name}:#{store.owner_id}" }
    name = ""

    before_each do
      StopBufferedJob.reset
      name = "stop_buffered_#{Random::Secure.hex(4)}"
    end

    after_each do
      StopBufferedJob::RELEASE.set(true)
      redis.del(name, owned.call(name))
    end

    it "releases them so the next start recovers and runs them once" do
      previous = JoobQ.config.worker_batch_size
      # Batch 1: the busy worker takes nothing more, one claim waits in the channel and the next one in `deliver`.
      JoobQ.config.worker_batch_size = 1
      a = Queue(StopBufferedJob).new(name, 1)
      b = Queue(StopBufferedJob).new(name, 1)
      staged = ["staged-1", "staged-2"]
      begin
        a.add(StopBufferedJob.new("blocker", name).to_json)
        staged.each { |label| a.add(StopBufferedJob.new(label, name).to_json) }
        a.start
        eventually { StopBufferedJob.runs("blocker") == 1 && redis.llen(owned.call(name)) == 3 }.should be_true

        a.stop!
        StopBufferedJob::RELEASE.set(true)
        eventually { !InFlight.any?(name) }.should be_true
        eventually { redis.llen(owned.call(name)) == 2 }.should be_true
        staged.each { |label| StopBufferedJob.runs(label).should eq(0) }
        b.start
        eventually { staged.all? { |label| StopBufferedJob.runs(label) == 1 } }.should be_true
        eventually { redis.llen(owned.call(name)) == 0 }.should be_true
        eventually(300.milliseconds) { staged.any? { |label| StopBufferedJob.runs(label) > 1 } }.should be_false
        StopBufferedJob.runs("blocker").should eq(1)
      ensure
        StopBufferedJob::RELEASE.set(true)
        a.stop!
        b.stop!
        JoobQ.config.worker_batch_size = previous || 10
      end
    end

    it "leaves them claimed during a shutdown, whose own requeue puts them back at the head" do
      previous = JoobQ.config.worker_batch_size
      JoobQ.config.worker_batch_size = 1
      a = Queue(StopBufferedJob).new(name, 1)
      staged = ["staged-1", "staged-2"]
      begin
        a.add(StopBufferedJob.new("blocker", name).to_json)
        staged.each { |label| a.add(StopBufferedJob.new(label, name).to_json) }
        a.start
        eventually { StopBufferedJob.runs("blocker") == 1 && redis.llen(owned.call(name)) == 3 }.should be_true
        JoobQ.spec_shut_down(true) # what `JoobQ.shutdown` sets before it stops the queues
        a.stop!
        StopBufferedJob::RELEASE.set(true)
        eventually { InFlight.count == 2 }.should be_true
        # The shutdown's step 5 (`requeue_unfinished`): abandon what is still claimed and put it back at the head.
        abandoned = InFlight.abandon_all.select { |(queue, _)| queue == name }
        abandoned.map { |(_, job)| StopBufferedJob.from_json(job).label }.should eq(staged)
        store.requeue_many_from_processing(abandoned).should eq(2)
        redis.lrange(name, 0, -1).map { |job| StopBufferedJob.from_json(job.to_s).label }.should eq(staged)
        redis.llen(owned.call(name)).should eq(0)
      ensure
        JoobQ.spec_shut_down(false)
        StopBufferedJob::RELEASE.set(true)
        a.stop!
        InFlight.clear
        JoobQ.config.worker_batch_size = previous || 10
      end
    end
  end
end
