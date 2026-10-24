require "./spec_helper"
require "file_utils"

# `JoobQ.shutdown` stops the queues of the process for good, so the end to end behaviour is checked in a child
# process (spec/fixtures/shutdown_probe.cr), and the pieces in this process.
class PollCountingScheduler < JoobQ::Scheduler
  getter polls = Atomic(Int32).new(0)

  def enqueue_due_jobs(current_time = Time.local)
    @polls.add(1)
  end
end

module JoobQ
  describe "orderly shutdown" do
    describe InFlight do
      it "waits for the jobs that are executing, up to the timeout" do
        InFlight.started
        InFlight.wait(50.milliseconds).should be_false
        spawn do
          sleep 30.milliseconds
          InFlight.finished
        end
        InFlight.wait(2.seconds).should be_true
        InFlight.count.should eq(0)
      end
    end

    describe Scheduler do
      it "stops the loop started by run" do
        scheduler = PollCountingScheduler.new
        scheduler.run
        eventually { scheduler.polls.get == 1 }.should be_true
        scheduler.stop
        scheduler.stop # harmless twice
        scheduler.run  # a stopped scheduler can be run again
        eventually { scheduler.polls.get == 2 }.should be_true
        scheduler.stop
      end
    end

    describe APIServer do
      it "stop does nothing when no server runs" do
        APIServer.stop
      end
    end

    describe "as a process" do
      binary = File.join(Dir.tempdir, "joobq-shutdown-probe-#{Random::Secure.hex(4)}")

      Spec.after_suite { File.delete?(binary) }

      build = -> do
        unless File.exists?(binary)
          source = File.expand_path("fixtures/shutdown_probe.cr", __DIR__)
          output = IO::Memory.new
          status = Process.run("crystal", ["build", source, "-o", binary], output: output, error: output)
          raise "probe did not build:\n#{output}" unless status.success?
        end
      end

      run_probe = ->(env : Hash(String, String), dir : String) do
        process = Process.new(binary, env: env.merge({"PROBE_DIR" => dir}), output: Process::Redirect::Close, error: Process::Redirect::Close)
        eventually(15.seconds) { File.exists?(File.join(dir, "started")) }.should be_true
        process.signal(Signal::TERM)
        started = Time.instant
        done = Channel(Process::Status).new(1)
        spawn { done.send(process.wait) }
        select
        when status = done.receive
          {status, Time.instant - started}
        when timeout(30.seconds)
          process.terminate
          raise "the probe did not exit after SIGTERM"
        end
      end

      it "forge shuts down on SIGTERM: waits for the running job, then exits 0" do
        build.call
        dir = File.join(Dir.tempdir, "joobq-probe-#{Random::Secure.hex(4)}")
        Dir.mkdir_p(dir)
        begin
          status, elapsed = run_probe.call({"JOOBQ_ENV" => "test"}, dir)
          status.success?.should be_true
          File.exists?(File.join(dir, "done")).should be_true
          elapsed.should be < 14.seconds
        ensure
          FileUtils.rm_rf(dir)
        end
      end

      it "leaves the signals alone with JOOBQ_TRAP_SIGNALS=0" do
        build.call
        dir = File.join(Dir.tempdir, "joobq-probe-#{Random::Secure.hex(4)}")
        Dir.mkdir_p(dir)
        begin
          status, _ = run_probe.call({"JOOBQ_ENV" => "test", "JOOBQ_TRAP_SIGNALS" => "0"}, dir)
          status.success?.should be_false
          status.signal_exit?.should be_true
        ensure
          FileUtils.rm_rf(dir)
        end
      end
    end
  end
end
