require "spec"
require "../src/joobq"
require "./jobs/*"

JoobQ.configure do
  queue "single", 10, Job1
  queue "example", 10, ExampleJob
  queue "failed", 10, FailJob

  scheduler do
    cron("*/1 * * * *") { }
    cron("*/5 20-23 * * *") { }
    every 1.second, ExampleJob, x: 1
  end
end
