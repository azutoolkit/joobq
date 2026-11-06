require "joobq"

struct SendInvoiceEmailJob
  include JoobQ::Job

  @queue = "invoices"
  getter invoice_id : Int64
  getter email : String

  def initialize(@invoice_id : Int64, @email : String)
  end

  def perform
    puts "Sent invoice #{invoice_id} to #{email}"
  end
end

JoobQ.configure do |config|
  config.rest_api_enabled = false
  queue "invoices", 2, SendInvoiceEmailJob
end

SendInvoiceEmailJob.enqueue(invoice_id: 1001_i64, email: "ada@example.com")
stored = JSON.parse(JoobQ::RedisStore.instance.redis.lindex("invoices", 0).to_s)
puts "Stored fields: #{stored.as_h.keys.sort.join(", ")}"
puts "retries=#{stored["retries"]} status=#{stored["status"]}"
JoobQ.forge
