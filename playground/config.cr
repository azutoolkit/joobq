require "../src/joobq"
require "./jobs/*"

JoobQ.configure do |config|
  config.rest_api_enabled = true

  queue name: "queue:test", workers: 5, job: TestJob, throttle: nil
  # queue "queue:fail", 5, FailJob
  # queue "queue:expire", 1, ExpireJob
end
