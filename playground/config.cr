JoobQ.configure do |_|
  queue name: "queue:test", workers: 5, job: TestJob, throttle: nil
  queue "queue:fail", 5, FailJob
  queue "queue:expire", 1, ExpireJob
end
