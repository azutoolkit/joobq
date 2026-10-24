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
        port = 38_000 + Random.rand(2_000)
        returned = Channel(Nil).new(1)
        spawn do
          APIServer.start("127.0.0.1", port)
        rescue
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
