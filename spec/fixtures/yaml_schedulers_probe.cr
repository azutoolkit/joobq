# Runs `JoobQ.forge` with one YAML recurring entry and shuts it down after a few seconds, printing what ran.
# PROBE_MODE: on (the entry fires every second), off (fire_yaml_schedulers is false and the entry is bad), bad (an entry
# whose job is not registered, which must stop forge before anything starts). Needs REDIS_PORT of a throwaway Redis.
require "../../src/joobq"

PERFORMED = Atomic(Int32).new(0)

class ProbeScheduledJob
  include JoobQ::Job

  def initialize
    @queue = "yaml_probe_queue"
  end

  def perform
    PERFORMED.add(1)
    puts "PERFORMED"
  end
end

JoobQ::QueueFactory.register_job_type(ProbeScheduledJob)

mode = ENV["PROBE_MODE"]
job = mode == "off" || mode == "bad" ? "NoSuchJob" : "ProbeScheduledJob"
flag = mode == "off" ? "false" : "true"

JoobQ.set_config(JoobQ::YamlConfigLoader.load_from_string(<<-YAML))
  joobq:
    settings:
      fire_yaml_schedulers: #{flag}
    queues:
      yaml_probe_queue:
        job_class: "ProbeScheduledJob"
        workers: 1
    schedulers:
      - timezone: "UTC"
        recurring_jobs:
          - interval: "1 second"
            job: "#{job}"
  YAML
JoobQ.store.clear_queue("yaml_probe_queue")

# Jobs run, waiting or in flight: it grows only while an entry keeps enqueuing (the stopped workers run nothing).
total = -> { PERFORMED.get + JoobQ.store.queue_size("yaml_probe_queue") + JoobQ.store.processing_queue_size("yaml_probe_queue") }

spawn do
  # Shut down once the entry has fired (or, when nothing should fire, after a short while).
  deadline = Time.instant + (mode == "on" ? 10.seconds : 2.5.seconds)
  until (mode == "on" && PERFORMED.get >= 1) || Time.instant >= deadline
    sleep 20.milliseconds
  end
  JoobQ.shutdown
end

begin
  JoobQ.forge(trap_signals: false)
rescue ex
  puts "FAILED #{ex.class}: #{ex.message}"
  exit 1
end

# forge has returned: the workers and the entries are stopped, so the total must not move.
before = total.call
sleep 2.5.seconds
puts "COUNT before=#{before} after=#{total.call}"
