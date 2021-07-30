require "spec"
require "../src/joobq"
require "./jobs/*"

JoobQ.configure do
  queue "single", 10, Job1
  queue "example", 10, ExampleJob | FailJob

  scheduler do
    cron("*/1 * * * *") { }
    cron("*/5 20-23 * * *") { }
    every 1.hour, ExampleJob, x: 1
  end
end
