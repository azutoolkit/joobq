require "../src/joobq"
require "./jobs/*"

JoobQ.configure do |_|
  queue "queue:test", 80, TestJob
  queue "queue:fail", 20, FailJob
end

1_000.times do |i|
  TestJob.perform(x: i)
  # FailJob.perform
end

puts "Enqueued 1,000,000 jobs"
