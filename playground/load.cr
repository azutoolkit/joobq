require "../src/joobq"
require "./jobs/*"
require "./config"

1_000_000.times do |i|
  TestJob.enqueue(x: i)
  # FailJob.perform
  # ExpireJob.perform
end

puts "Enqueued 1,000,000 jobs"
