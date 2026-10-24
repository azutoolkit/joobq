require "../../src/joobq"

# A tiny program for spec/shutdown_spec.cr. It uses the Redis named by REDIS_HOST / REDIS_PORT and the queue named
# by PROBE_QUEUE, and writes into the directory PROBE_DIR. Modes (PROBE_MODE):
#
# * "stuck" (default): PROBE_JOBS jobs that never finish; `forge` runs with PROBE_TIMEOUT seconds of shutdown budget.
# * "slow": one job of one second; each job writes `started-<jid>` (one line per run) and, when it ends, `done`.
# * "concurrent": no jobs; three fibers call `JoobQ.shutdown` at once and `results` gets what each returned.
#
# The watchdog ends the program if the spec forgot it.
spawn do
  sleep 120.seconds
  exit 2
end

class ProbeJob
  include JoobQ::Job

  def initialize
    @queue = ENV["PROBE_QUEUE"]
  end

  def perform
    File.open(File.join(ENV["PROBE_DIR"], "started-#{jid}"), "a") { |f| f.puts "run" }
    if ENV["PROBE_MODE"]? == "slow"
      sleep 1.second
      File.write(File.join(ENV["PROBE_DIR"], "done"), "1")
    else
      sleep 60.seconds
    end
  end
end

mode = ENV["PROBE_MODE"]? || "stuck"

JoobQ.set_config(JoobQ::Configure.new)
JoobQ.config.timeout = 10.minutes
JoobQ.configure do
  queue ENV["PROBE_QUEUE"], 1, ProbeJob
end

case mode
when "concurrent"
  JoobQ.config.queues.each_value(&.start)
  results = Channel(Bool).new(3)
  3.times { spawn { results.send(JoobQ.shutdown(2.seconds)) } }
  answers = Array(Bool).new(3) { results.receive }
  File.write(File.join(ENV["PROBE_DIR"], "results"), answers.sort_by { |a| a ? 1 : 0 }.join(","))
  exit 0
else
  (mode == "slow" ? 1 : (ENV["PROBE_JOBS"]? || "5").to_i).times { JoobQ.add(ProbeJob.new) }
  JoobQ.config.queues.each_value(&.start)
  JoobQ.forge(shutdown_timeout: (ENV["PROBE_TIMEOUT"]? || "15").to_f.seconds)
end
