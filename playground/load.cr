require "./config"

1_000_000.times do |i|
  TestJob.enqueue(x: i)
  # FailJob.enqueue
  # ExpireJob.enqueue
end

puts "Enqueued 1,000,000 jobs"
