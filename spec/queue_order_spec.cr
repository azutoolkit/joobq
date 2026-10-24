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
    # Characterization: pins today's behaviour, not the documented intent.
    # enqueue uses RPUSH (redis_store.cr:84) and dequeue uses BRPOPLPUSH
    # (redis_store.cr:134), so both act on the right end of the list and the
    # newest job comes out first: last-in-first-out, despite FIFO comments.
    it "current order: one worker runs jobs enqueued A, B, C as C, B, A" do
      redis = JoobQ.store.as(RedisStore).redis
      keys = [OrderRecordingJob::QUEUE, "joobq:processing:#{OrderRecordingJob::QUEUE}"]
      keys.each { |key| redis.del(key) }
      OrderRecordingJob::RAN.clear

      queue = Queue(OrderRecordingJob).new(OrderRecordingJob::QUEUE, 1)
      begin
        %w[A B C].each { |label| queue.add OrderRecordingJob.new(label).to_json }

        queue.start
        eventually(10.seconds) { OrderRecordingJob::RAN.size == 3 }.should be_true

        OrderRecordingJob::RAN.should eq(%w[C B A])
      ensure
        queue.stop!
        keys.each { |key| redis.del(key) }
      end
    end
  end
end
