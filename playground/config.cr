require "../src/joobq"
require "./jobs/*"

JoobQ.configure do |config|
  config.rest_api_enabled = true

  queue name: "queue:test", workers: 2, job: TestJob, throttle: nil
  queue name: "queue:fail", workers: 1, job: FailJob
  queue name: "queue:expire", workers: 1, job: ExpireJob

  scheduler do
    cron(pattern: "*/5 * * * * *") { puts "Every 30 seconds #{Time.local}" }
    cron(pattern: "*/5 * * * * *") { }
    every(1.minute, TestJob, x: 1)
  end
end
