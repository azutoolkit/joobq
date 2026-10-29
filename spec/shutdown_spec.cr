require "./spec_helper"
require "file_utils"

# `JoobQ.shutdown` stops the queues of a process for good, so its end to end behaviour is checked in child processes
# (spec/fixtures/shutdown_probe.cr, which needs REDIS_PORT to name a throwaway Redis) and the pieces in this one.
class PollCountingScheduler < JoobQ::Scheduler
  getter polls = Atomic(Int32).new(0)

  def enqueue_due_jobs(current_time = Time.local)
    @polls.add(1)
  end
end

class FailingPollScheduler < JoobQ::Scheduler
  getter polls = Atomic(Int32).new(0)

  def enqueue_due_jobs(current_time = Time.local)
    @polls.add(1)
    raise "redis is away" if @polls.get < 3
  end
end

# Specs only: reach into the parts of the library that cannot be driven from outside.
module JoobQ
  def self.spec_shut_down(value : Bool) : Nil
    @@shut_down.set(value)
  end
end

class JoobQ::Worker(T)
  def test_unparseable(job_json : String, error : Exception) : Nil
    handle_unparseable_job(job_json, error)
  end
end

PROBE_BINARY = File.join(Dir.tempdir, "joobq-shutdown-probe-#{Random::Secure.hex(4)}")
Spec.after_suite { File.delete?(PROBE_BINARY) }

def build_probe : Nil
  return if File.exists?(PROBE_BINARY)

  source = File.expand_path("fixtures/shutdown_probe.cr", __DIR__)
  output = IO::Memory.new
  status = Process.run("crystal", ["build", source, "-o", PROBE_BINARY], output: output, error: output)
  raise "probe did not build:\n#{output}" unless status.success?
end

# Runs a probe with a fresh queue name and directory, yields the process, and always ends and cleans up.
def with_probe(mode : String, extra = {} of String => String, &)
  build_probe
  queue = "shutdown_probe_#{Random::Secure.hex(4)}"
  dir = File.join(Dir.tempdir, "joobq-probe-#{Random::Secure.hex(4)}")
  Dir.mkdir_p(dir)
  env = {"PROBE_QUEUE" => queue, "PROBE_DIR" => dir, "PROBE_MODE" => mode, "JOOBQ_ENV" => "test"}.merge(extra)
  process = Process.new(PROBE_BINARY, env: env, input: Process::Redirect::Close, output: Process::Redirect::Close,
    error: Process::Redirect::Close)
  redis = JoobQ.store.as(JoobQ::RedisStore).redis
  begin
    yield process, queue, dir, redis
  ensure
    unless process.terminated?
      process.signal(Signal::KILL) rescue nil
      process.wait rescue nil
    end
    redis.del(queue, "joobq:processing:#{queue}")
    FileUtils.rm_rf(dir)
  end
end

# Waits for the process to exit; ends the example (the process is killed by `with_probe`) when it does not.
def exit_of(process : Process, within : Time::Span) : Process::Status
  done = Channel(Process::Status).new(1)
  spawn { done.send(process.wait) }
  select
  when status = done.receive
    status
  when timeout(within)
    raise "the probe did not exit within #{within}"
  end
end

def wait_for_files(dir : String, prefix : String, count : Int32) : Nil
  eventually(15.seconds) { Dir.glob(File.join(dir, "#{prefix}*")).size >= count }.should be_true
end

module JoobQ
  describe "orderly shutdown" do
    describe InFlight do
      after_each { InFlight.clear }

      it "waits for the jobs that are executing, up to the timeout" do
        token = InFlight.claimed("q", ["a"]).first
        begin
          InFlight.begin_run(token).should be_true
          InFlight.wait(50.milliseconds).should be_false
          spawn do
            sleep 30.milliseconds
            InFlight.finished(token)
          end
          InFlight.wait(2.seconds).should be_true
          InFlight.count.should eq(0)
        ensure
          InFlight.clear
        end
      end

      it "abandons claimed and running jobs: they are not counted, not started, and their end is reported" do
        a, b = InFlight.claimed("q1", ["a", "b"])
        c = InFlight.claimed("q2", ["c"]).first
        InFlight.begin_run(a)

        InFlight.abandon_all.sort.should eq([{"q1", "a"}, {"q1", "b"}, {"q2", "c"}])
        InFlight.count.should eq(0)
        InFlight.begin_run(b).should be_false # claimed, never started: it must not start now
        InFlight.finished(a).should be_true   # it was running: its cleanup is skipped
        InFlight.finished(b).should be_true
        InFlight.finished(c).should be_true
        InFlight.abandon_all.should be_empty
      end

      it "keeps claims of identical raw strings apart" do
        first, second = InFlight.claimed("q", ["same", "same"])
        first.should_not eq(second)
        InFlight.count.should eq(2)
        InFlight.finished(first).should be_false
        InFlight.count.should eq(1)
        InFlight.finished(second).should be_false
        InFlight.count.should eq(0)
      end

      it "reports a normal end as not abandoned" do
        token = InFlight.claimed("q", ["a"]).first
        InFlight.begin_run(token)
        InFlight.abandoned?.should be_false
        InFlight.finished(token).should be_false
      end

      it "knows the fiber of an abandoned execution, and only that fiber" do
        token = InFlight.claimed("q", ["a"]).first
        seen = Channel(Bool).new(1)
        go = Channel(Nil).new
        spawn do
          InFlight.begin_run(token)
          go.receive
          seen.send(InFlight.abandoned?)
        end
        sleep 20.milliseconds
        InFlight.abandoned?.should be_false # this fiber runs no claimed job
        InFlight.abandon_all
        go.send(nil)
        seen.receive.should be_true
        InFlight.abandoned?.should be_false
      end
    end

    describe "the failure handling of an abandoned execution" do
      jid_in = ->(redis : Redis::PooledClient, key : String, jid : String) do
        redis.zrange(key, 0, -1).any? { |entry| entry.to_s.includes?(jid) }
      end

      # Runs the retry middleware around a job that sleeps and then raises, optionally abandoning it meanwhile.
      run_failing = ->(retries : Int32, abandon : Bool) do
        queue = JoobQ.queues["example"]
        job = ExampleJob.new
        job.retries = retries
        token = InFlight.claimed("example", [job.to_json]).first
        done = Channel(Nil).new
        spawn do
          InFlight.begin_run(token)
          failing = Proc(Nil).new { sleep 100.milliseconds; raise "boom" }
          JoobQ::Middleware::Retry.new.call(job, queue, "w", failing)
        ensure
          InFlight.finished(token)
          done.send(nil)
        end
        sleep 30.milliseconds
        InFlight.abandon_all if abandon
        done.receive
        job.jid.to_s
      end

      after_each { InFlight.clear }

      it "control: a running execution that fails with retries left is scheduled for a retry" do
        redis = JoobQ.store.as(JoobQ::RedisStore).redis
        jid = run_failing.call(3, false)
        jid_in.call(redis, "joobq:delayed_jobs", jid).should be_true
        redis.zrem("joobq:delayed_jobs", redis.zrange("joobq:delayed_jobs", 0, -1).select { |e| e.to_s.includes?(jid) })
      end

      it "control: a running execution that fails without retries left is dead-lettered" do
        redis = JoobQ.store.as(JoobQ::RedisStore).redis
        jid = run_failing.call(0, false)
        jid_in.call(redis, "joobq:dead_letter", jid).should be_true
        redis.zrem("joobq:dead_letter", redis.zrange("joobq:dead_letter", 0, -1).select { |e| e.to_s.includes?(jid) })
      end

      it "an abandoned execution that fails is not scheduled a second time" do
        redis = JoobQ.store.as(JoobQ::RedisStore).redis
        jid = run_failing.call(3, true)
        jid_in.call(redis, "joobq:delayed_jobs", jid).should be_false
        jid_in.call(redis, "joobq:dead_letter", jid).should be_false
      end

      it "an abandoned execution that fails with no retries left is not dead-lettered" do
        redis = JoobQ.store.as(JoobQ::RedisStore).redis
        jid = run_failing.call(0, true)
        jid_in.call(redis, "joobq:dead_letter", jid).should be_false
        jid_in.call(redis, "joobq:delayed_jobs", jid).should be_false
      end
    end

    describe "settling" do
      after_each { InFlight.clear }

      # Runs the block in a fiber that runs a claimed job, abandoning the claim first when asked.
      run_claimed = ->(abandon : Bool, body : -> Nil) do
        token = InFlight.claimed("example", ["{}"]).first
        ready = Channel(Nil).new
        go = Channel(Nil).new
        done = Channel(Nil).new
        spawn do
          InFlight.begin_run(token)
          ready.send(nil)
          go.receive
          begin
            body.call
          ensure
            InFlight.finished(token)
            done.send(nil)
          end
        end
        ready.receive
        InFlight.abandon_all if abandon
        go.send(nil)
        done.receive
      end

      it "settle is true for a fiber that runs no claimed job" do
        InFlight.settle.should be_true
      end

      it "a settling job is not abandoned by the usual pass, still counts, and is taken by the last resort" do
        token = InFlight.claimed("q", ["a"]).first
        entered = Channel(Nil).new
        leave = Channel(Nil).new
        result = Channel(Bool).new(1)
        spawn do
          InFlight.begin_run(token)
          InFlight.settle.should be_true
          entered.send(nil)
          leave.receive
          result.send(InFlight.finished(token))
        end
        entered.receive
        InFlight.abandon_all.should be_empty
        InFlight.count.should eq(1)
        InFlight.abandon_all(settling: true).should eq([{"q", "a"}])
        InFlight.count.should eq(0)
        leave.send(nil)
        result.receive.should be_true # abandoned after all: its end is reported
      end

      it "settle after an abandonment answers false, once" do
        saw = Channel(Bool).new(1)
        run_claimed.call(true, -> { saw.send(InFlight.settle); nil })
        saw.receive.should be_false
      end

      it "a failure being settled when shutdown looks is not requeued, and its retry is scheduled exactly once" do
        redis = JoobQ.store.as(JoobQ::RedisStore).redis
        queue = JoobQ.queues["example"]
        job = ExampleJob.new
        job.retries = 3
        taken = [] of {String, String}
        InFlight.after_settle = -> do
          InFlight.after_settle = nil
          taken.concat(InFlight.abandon_all) # shutdown looks right between the settle and the retry scheduling
          nil
        end
        run_claimed.call(false, -> do
          JoobQ::Middleware::Retry.new.call(job, queue, "w", Proc(Nil).new { raise "boom" })
          nil
        end)
        taken.should be_empty
        scheduled = redis.zrange("joobq:delayed_jobs", 0, -1).select { |e| e.to_s.includes?(job.jid.to_s) }
        scheduled.size.should eq(1)
        redis.zrem("joobq:delayed_jobs", scheduled)
      end

      it "ErrorHandler.handle_job_error with schedule: true neither schedules nor announces for an abandoned execution" do
        redis = JoobQ.store.as(JoobQ::RedisStore).redis
        queue = JoobQ.queues["example"]
        sink = CollectingSink.new
        Events.subscribe(sink)
        begin
          [true, false].each do |abandon|
            job = ExampleJob.new
            job.retries = 3
            run_claimed.call(abandon, -> do
              ErrorHandler.handle_job_error(job, queue, Exception.new("bad"), "w", schedule: true)
              nil
            end)
            sleep 300.milliseconds
            seen = [] of String
            loop do
              select
              when event = sink.received.receive
                seen << event.type if event.data.to_s.includes?(job.jid.to_s)
              else
                break
              end
            end
            where = redis.zrange("joobq:delayed_jobs", 0, -1).any? { |e| e.to_s.includes?(job.jid.to_s) } ||
                    redis.zrange("joobq:dead_letter", 0, -1).any? { |e| e.to_s.includes?(job.jid.to_s) }
            if abandon
              where.should be_false
              seen.should_not contain("job.failed")
            else
              where.should be_true
              seen.should contain("job.failed")
              redis.zremrangebyscore("joobq:delayed_jobs", "-inf", "+inf")
              redis.zremrangebyscore("joobq:dead_letter", "-inf", "+inf")
            end
          end
        ensure
          Events.unsubscribe(sink)
        end
      end

      it "the timeout middleware dead-letters an expired job unless its execution was abandoned" do
        redis = JoobQ.store.as(JoobQ::RedisStore).redis
        queue = JoobQ.queues["example"]
        [true, false].each do |abandon|
          job = ExampleJob.new
          job.expires = 0_i64
          run_claimed.call(abandon, -> do
            JoobQ::Middleware::Timeout.new.call(job, queue, "w", -> { })
            nil
          end)
          dead = redis.zrange("joobq:dead_letter", 0, -1).select { |e| e.to_s.includes?(job.jid.to_s) }
          dead.empty?.should eq(abandon)
          redis.zrem("joobq:dead_letter", dead) unless dead.empty?
        end
      end

      it "an unparseable job is dead-lettered unless its execution was abandoned" do
        redis = JoobQ.store.as(JoobQ::RedisStore).redis
        queue = JoobQ.queues["example"]
        worker = Worker(ExampleJob).new(1, Channel(Nil).new(1), queue)
        [true, false].each do |abandon|
          before = redis.zcard("joobq:dead_letter")
          run_claimed.call(abandon, -> do
            worker.test_unparseable("{\"jid\": \"not-a-job", Exception.new("bad json"))
            nil
          end)
          (redis.zcard("joobq:dead_letter") - before).should eq(abandon ? 0 : 1)
        end
        redis.zremrangebyscore("joobq:dead_letter", "-inf", "+inf")
      end
    end

    describe "claiming" do
      it "a worker claims nothing once the shutdown has begun" do
        name = "claim_guard_#{Random::Secure.hex(3)}"
        queue = JoobQ::Queue(ExampleJob).new(name, 1) # a queue of its own: the shared ones are stopped between examples
        job = ExampleJob.from_json(ExampleJob.new.to_json.sub("\"queue\":\"example\"", "\"queue\":\"#{name}\""))
        JoobQ.spec_shut_down(true)
        begin
          queue.start
          queue.add(job)
          sleep 600.milliseconds
          queue.size.should eq(1)
        ensure
          JoobQ.spec_shut_down(false)
        end
        eventually(5.seconds) { queue.size == 0 }.should be_true # the guard was the only thing holding it back
      ensure
        queue.try(&.stop!)
        queue.try(&.clear)
      end
    end

    describe "RedisStore#requeue_many_from_processing" do
      it "puts back what is in the processing list, skips what is not, and does nothing twice" do
        store = JoobQ.store.as(JoobQ::RedisStore)
        redis = store.redis
        qa = "requeue_a_#{Random::Secure.hex(3)}"
        qb = "requeue_b_#{Random::Secure.hex(3)}"
        begin
          redis.rpush("joobq:processing:#{qa}", "a1", "a2")
          redis.rpush("joobq:processing:#{qb}", "b1")
          entries = [{qa, "a1"}, {qa, "missing"}, {qb, "b1"}, {qa, "a2"}]

          store.requeue_many_from_processing(entries).should eq(3)
          redis.lrange(qa, 0, -1).map(&.to_s).sort.should eq(["a1", "a2"])
          redis.lrange(qb, 0, -1).should eq(["b1"])
          redis.llen("joobq:processing:#{qa}").should eq(0)

          store.requeue_many_from_processing(entries).should eq(0) # nothing is queued twice
          redis.llen(qa).should eq(2)
          store.requeue_many_from_processing([] of {String, String}).should eq(0)
        ensure
          redis.del(qa, qb, "joobq:processing:#{qa}", "joobq:processing:#{qb}")
        end
      end

      it "skips an entry whose keys fail (wrong type) without losing the others or desyncing the connection" do
        store = JoobQ.store.as(JoobQ::RedisStore)
        redis = store.redis
        good = "requeue_good_#{Random::Secure.hex(3)}"
        bad = "requeue_bad_#{Random::Secure.hex(3)}"
        begin
          redis.set("joobq:processing:#{bad}", "not a list")
          redis.rpush("joobq:processing:#{good}", "g1")

          store.requeue_many_from_processing([{bad, "x"}, {good, "g1"}]).should eq(1)
          redis.lrange(good, 0, -1).should eq(["g1"])
          redis.ping.should eq("PONG") # the connection still answers in step
          redis.get("joobq:processing:#{bad}").should eq("not a list")
        ensure
          redis.del(good, bad, "joobq:processing:#{good}", "joobq:processing:#{bad}")
        end
      end
    end

    describe "signal handling settings" do
      it "reads JOOBQ_TRAP_SIGNALS" do
        previous = ENV["JOOBQ_TRAP_SIGNALS"]?
        begin
          ENV.delete("JOOBQ_TRAP_SIGNALS")
          JoobQ.trap_signals_default?.should be_true
          {"0", "false", "FALSE", "no", "No"}.each do |value|
            ENV["JOOBQ_TRAP_SIGNALS"] = value
            JoobQ.trap_signals_default?.should be_false
          end
          {"1", "true", "yes", ""}.each do |value|
            ENV["JOOBQ_TRAP_SIGNALS"] = value
            JoobQ.trap_signals_default?.should be_true
          end
        ensure
          previous ? (ENV["JOOBQ_TRAP_SIGNALS"] = previous) : ENV.delete("JOOBQ_TRAP_SIGNALS")
        end
      end
    end

    describe Scheduler do
      it "stops the loop started by run, and can run again" do
        scheduler = PollCountingScheduler.new
        scheduler.run
        eventually { scheduler.polls.get == 1 }.should be_true
        scheduler.stop
        scheduler.stop # harmless twice
        scheduler.run
        eventually { scheduler.polls.get == 2 }.should be_true
        scheduler.stop
      end

      it "retries after a failing poll with a backoff, then carries on" do
        scheduler = FailingPollScheduler.new
        started = Time.instant
        scheduler.run
        begin
          eventually(10.seconds) { scheduler.polls.get >= 3 }.should be_true
          # two failures: backoffs of about 1 s and 2 s (plus jitter), so not instantly
          (Time.instant - started).should be > 2.seconds
        ensure
          scheduler.stop
        end
      end
    end

    describe APIServer do
      it "stop does nothing when no server runs" do
        APIServer.stop
      end

      it "stop closes a listening server and start returns" do
        # Ask the OS for an unused port; a random fixed range can hit another service.
        reservation = TCPServer.new("127.0.0.1", 0)
        port = reservation.local_address.port
        reservation.close
        returned = Channel(Nil).new(1)
        errors = Channel(Exception).new(1)
        spawn do
          APIServer.start("127.0.0.1", port, policy: ManagementPolicy.new({"spec-token-" * 4 => ManagementPolicy::Role::Admin}))
        rescue ex
          errors.send(ex)
        ensure
          returned.send(nil)
        end

        listening = eventually(5.seconds) do
          TCPSocket.new("127.0.0.1", port).close
          true
        rescue
          false
        end
        begin
          select
          when error = errors.receive
            raise error
          else
          end
          listening.should be_true
        ensure
          APIServer.stop
        end
        select
        when returned.receive
        when timeout(5.seconds)
          fail "APIServer.start did not return after stop"
        end
      end
    end

    describe "as a process" do
      before_each { pending!("REDIS_PORT must name a throwaway Redis for the probe") unless ENV["REDIS_PORT"]? }

      it "forge shuts down on SIGTERM: waits for the running job, then exits 0" do
        with_probe("slow") do |process, queue, dir, redis|
          wait_for_files(dir, "started-", 1)
          process.signal(Signal::TERM)
          started = Time.instant
          exit_of(process, 30.seconds).exit_code.should eq(0)
          (Time.instant - started).should be < 14.seconds
          File.exists?(File.join(dir, "done")).should be_true
          redis.llen(queue).should eq(0)
          redis.llen("joobq:processing:#{queue}").should eq(0)
        end
      end

      it "returns ALL stuck jobs to their queue at the deadline, exits 3, and runs none of them twice" do
        with_probe("stuck", {"PROBE_JOBS" => "5", "PROBE_TIMEOUT" => "2"}) do |process, queue, dir, redis|
          wait_for_files(dir, "started-", 5)
          redis.llen("joobq:processing:#{queue}").should eq(5)
          process.signal(Signal::TERM)
          started = Time.instant
          exit_of(process, 30.seconds).exit_code.should eq(3)
          (Time.instant - started).should be < 8.seconds

          redis.llen(queue).should eq(5)
          redis.llen("joobq:processing:#{queue}").should eq(0)
          sleep 500.milliseconds # nothing is left to run them again
          files = Dir.glob(File.join(dir, "started-*"))
          files.size.should eq(5)
          files.each { |file| File.read_lines(file).size.should eq(1) }
        end
      end

      it "exits 1 at once on a second signal, a second or more after the first" do
        with_probe("stuck", {"PROBE_JOBS" => "1", "PROBE_TIMEOUT" => "30"}) do |process, _, dir, _|
          wait_for_files(dir, "started-", 1)
          process.signal(Signal::TERM)
          process.signal(Signal::TERM) # a duplicate right away is ignored
          sleep 1.5.seconds
          process.terminated?.should be_false
          process.signal(Signal::TERM)
          exit_of(process, 10.seconds).exit_code.should eq(1)
        end
      end

      it "does not schedule a requeued job a second time when its abandoned execution fails afterwards" do
        with_probe("failing", {"PROBE_TIMEOUT" => "1"}) do |process, queue, dir, redis|
          exit_of(process, 30.seconds).exit_code.should eq(0)
          redis.llen(queue).should eq(1)
          jid = File.basename(Dir.glob(File.join(dir, "started-*")).first).sub("started-", "")
          # the job raised after the shutdown gave up on it (the probe lives on for that), and nothing was scheduled
          File.exists?(File.join(dir, "raised")).should be_true
          redis.zrange("joobq:delayed_jobs", 0, -1).any? { |entry| entry.to_s.includes?(jid) }.should be_false
          redis.zrange("joobq:dead_letter", 0, -1).any? { |entry| entry.to_s.includes?(jid) }.should be_false
          redis.llen("joobq:processing:#{queue}").should eq(0)
        end
      end

      it "does not count, ack or announce an abandoned job that succeeds afterwards" do
        with_probe("succeeding", {"PROBE_TIMEOUT" => "1"}) do |process, queue, dir, redis|
          exit_of(process, 30.seconds).exit_code.should eq(0)
          File.exists?(File.join(dir, "finished")).should be_true # the abandoned execution did finish
          File.read(File.join(dir, "completed-events")).should eq("0")
          redis.llen(queue).should eq(1) # the requeued copy is untouched
          redis.llen("joobq:processing:#{queue}").should eq(0)
          redis.hget("joobq:stats:processed", queue).should be_nil
        end
      end

      it "answers every concurrent call to shutdown, and only the first does the work" do
        with_probe("concurrent") do |process, _, dir, _|
          exit_of(process, 30.seconds).exit_code.should eq(0)
          File.read(File.join(dir, "results")).should eq("false,false,true")
        end
      end

      it "leaves the signals alone with JOOBQ_TRAP_SIGNALS=0" do
        with_probe("slow", {"JOOBQ_TRAP_SIGNALS" => "0"}) do |process, _, dir, _|
          wait_for_files(dir, "started-", 1)
          process.signal(Signal::TERM)
          status = exit_of(process, 30.seconds)
          status.success?.should be_false
          status.signal_exit?.should be_true
        end
      end
    end
  end
end
