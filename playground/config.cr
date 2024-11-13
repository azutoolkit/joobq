JoobQ.configure do |_|
  queue "queue:test", 80, TestJob
  queue "queue:fail", 20, FailJob
end
