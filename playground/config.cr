JoobQ.configure do |_|
  queue "queue:test", 3, TestJob, nil
  # queue "queue:fail", 5, FailJob
  # queue "queue:expire", 1, ExpireJob, 10 # jobs per second
end
