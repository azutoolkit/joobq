require "joobq"

struct ResizeImageJob
  include JoobQ::Job

  @queue = "images"
  @@running = Atomic(Int32).new(0)
  @@peak = Atomic(Int32).new(0)
  @@done = Atomic(Int32).new(0)
  getter image_id : Int32

  def initialize(@image_id : Int32)
  end

  def self.peak
    @@peak.get
  end

  def self.done
    @@done.get
  end

  def perform
    @@peak.max(@@running.add(1) + 1)
    sleep 200.milliseconds
    @@running.sub(1)
    @@done.add(1)
  end
end

JoobQ.configure do |config|
  config.rest_api_enabled = false
  config.worker_batch_size = 3
  queue "images", 2, ResizeImageJob
end

12.times { |id| ResizeImageJob.enqueue(image_id: id) }
spawn { JoobQ.forge(trap_signals: false) }
until ResizeImageJob.done == 12
  sleep 100.milliseconds
end
JoobQ.shutdown(5.seconds)
puts "Peak jobs in flight: #{ResizeImageJob.peak} (2 workers x worker_batch_size 3)"
