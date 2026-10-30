require "joobq"

struct ProcessOrderJob
  include JoobQ::Job

  @queue = "orders"
  getter order_id : Int64

  def initialize(@order_id : Int64)
  end

  def perform
    puts "Processed order #{order_id}"
  end
end

JoobQ.configure do |config|
  config.rest_api_enabled = false
  queue "orders", 2, ProcessOrderJob
end

ProcessOrderJob.enqueue(order_id: 42_i64)
JoobQ.forge
