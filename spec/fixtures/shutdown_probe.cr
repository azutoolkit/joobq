require "../../src/joobq"

# A tiny program for spec/shutdown_spec.cr: runs `JoobQ.forge` with one slow job. The job writes `started` and,
# a moment later, `done` into the directory PROBE_DIR; the spec sends SIGTERM in between.
class SlowProbeJob
  include JoobQ::Job

  def initialize
    @queue = "shutdown_probe"
  end

  def perform
    File.write(File.join(ENV["PROBE_DIR"], "started"), "1")
    sleep 1.second
    File.write(File.join(ENV["PROBE_DIR"], "done"), "1")
  end
end

JoobQ.set_config(JoobQ::Configure.new)
JoobQ.configure do
  queue "shutdown_probe", 1, SlowProbeJob
end

JoobQ.config.queues.each_value(&.start)

spawn do
  JoobQ.add(SlowProbeJob.new)
end

JoobQ.forge
