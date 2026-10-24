require "../../src/joobq"

# A tiny program for spec/shutdown_spec.cr. It uses the Redis named by REDIS_HOST / REDIS_PORT and the queue named
# by PROBE_QUEUE, and writes into the directory PROBE_DIR. Modes (PROBE_MODE):
#
# * "stuck" (default): PROBE_JOBS jobs that never finish; `forge` runs with PROBE_TIMEOUT seconds of shutdown budget.
# * "slow": one job of one second; each job writes `started-<jid>` (one line per run) and, when it ends, `done`.
# * "failing" / "succeeding": one job that raises / returns after 1.5 s; the program shuts down once the job runs
#   and lives on for 3.5 s, then writes the number of job.completed events it saw into `completed-events`.
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
    case ENV["PROBE_MODE"]?
    when "slow"
      sleep 1.second
      File.write(File.join(ENV["PROBE_DIR"], "done"), "1")
    when "failing"
      sleep 1.5.seconds
      File.write(File.join(ENV["PROBE_DIR"], "raised"), "1")
      raise "boom after the shutdown gave up on this job"
    when "succeeding"
      sleep 1.5.seconds
      File.write(File.join(ENV["PROBE_DIR"], "finished"), "1")
    else
      sleep 60.seconds
    end
  end
end

class CountingSink
  include JoobQ::EventSink

  getter completed = Atomic(Int32).new(0)

  def publish(event : JoobQ::Event) : Nil
    completed.add(1) if event.type == "job.completed"
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
when "failing", "succeeding"
  # one job that fails (or succeeds) after 1.5 s; the shutdown (timeout PROBE_TIMEOUT) gives up on it first once it
  # runs, the program lives on and counts the job.completed events it sees
  sink = CountingSink.new
  JoobQ::Events.subscribe(sink)
  JoobQ.add(ProbeJob.new)
  JoobQ.config.queues.each_value(&.start)
  spawn do
    until Dir.glob(File.join(ENV["PROBE_DIR"], "started-*")).size >= 1
      sleep 20.milliseconds
    end
    JoobQ.shutdown(ENV["PROBE_TIMEOUT"].to_f.seconds)
  end
  sleep 3.5.seconds
  File.write(File.join(ENV["PROBE_DIR"], "completed-events"), sink.completed.get.to_s)
  exit 0
else
  (mode == "slow" ? 1 : (ENV["PROBE_JOBS"]? || "5").to_i).times { JoobQ.add(ProbeJob.new) }
  JoobQ.config.queues.each_value(&.start)
  JoobQ.forge(shutdown_timeout: (ENV["PROBE_TIMEOUT"]? || "15").to_f.seconds)
end
