require "../src/joobq"
require "colorize"

struct TestJob
  include JoobQ::Job

  property x : Int32
  @retries = 3
  @queue = "test"
  @priority = Random.rand(5)

  def initialize(@x : Int32)
  end

  def perform
    x + 1
  end
end

job_queue = JoobQ::JobQueue(TestJob).new
iter = 100
count = 10_000_i64
total = iter * count

# Load jobs
a = Time.local

total.times do |i|
  job_queue.enqueue(TestJob.new(1))
end

puts "Created #{job_queue.size} jobs in #{Time.local - a}"
sleep 2.seconds

puts "Starting processing"

spawn do
  a = Time.local
  loop do
    count = job_queue.size

    if count == 0
      b = Time.local
      puts "Done in #{b - a}: #{"%.3f" % (total / (b - a).to_f)} jobs/sec".colorize(:green)
      exit
    end
    puts "Pending: #{count}"
    sleep 0.2
  end
end

job_queue.process
sleep
