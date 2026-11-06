require "./spec_helper"

# Records the label of each job in the order a worker performs them.
class OrderRecordingJob
  include JoobQ::Job

  RAN   = [] of String
  QUEUE = "order_spec"

  getter label : String

  def initialize(@label : String = "")
    @queue = QUEUE
  end

  def perform
    RAN << @label
  end
end

module JoobQ
  describe "queue execution order" do
    # Producers RPUSH to the tail and workers claim from the head (LMOVE ... LEFT LEFT), so jobs run in the order
    # they were enqueued.
    it "runs A, B, C in enqueue order when a worker is limited to one active job" do
      previous_batch_size = JoobQ.config.worker_batch_size
      JoobQ.config.worker_batch_size = 1
      redis = JoobQ.store.as(RedisStore).redis
      keys = [OrderRecordingJob::QUEUE, "joobq:processing:#{OrderRecordingJob::QUEUE}"]
      keys.each { |key| redis.del(key) }
      OrderRecordingJob::RAN.clear

      queue = Queue(OrderRecordingJob).new(OrderRecordingJob::QUEUE, 1)
      begin
        %w[A B C].each { |label| queue.add OrderRecordingJob.new(label).to_json }

        queue.start
        eventually(10.seconds) { OrderRecordingJob::RAN.size == 3 }.should be_true

        OrderRecordingJob::RAN.should eq(%w[A B C])
      ensure
        queue.stop!
        JoobQ.config.worker_batch_size = previous_batch_size
        keys.each { |key| redis.del(key) }
      end
    end
  end
end
