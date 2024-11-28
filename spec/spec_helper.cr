require "spec"
require "../src/joobq"
require "./jobs_spec"

JoobQ.configure do
  queue "single", 10, Job1
  queue "example", 10, ExampleJob
  queue "failed", 10, FailJob

  scheduler do
    cron(pattern: "*/30 * * * *") { puts "Every 30 seconds #{Time.local}" }
    cron(pattern: "*/5 20-23 * * *") { }
    every(1.minute, ExampleJob, x: 1)
  end
end
