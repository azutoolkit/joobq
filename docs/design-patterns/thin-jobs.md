---
description: Keep a job small so its business operation is easy to test and reuse.
---

# Thin jobs

Let the job carry a small input and call a business operation. The operation should be useful without a queue, which makes it easier to test and reuse from an HTTP endpoint or command.

This runnable **Core** example formats a receipt summary. It does not send email. Install the [Core baseline](../introduction/compatibility.md) before running it.

{% code title="src/receipt_worker.cr" %}
<!-- example: core/thin_job.cr -->
```crystal
require "joobq"

# Application code; replace this formatter with your own business operation.
class ReceiptSummary
  def self.call(order_id : Int64, total_cents : Int32) : String
    raise ArgumentError.new("total must be non-negative") if total_cents < 0
    "Order #{order_id}: #{total_cents} cents"
  end
end

struct SummarizeReceiptJob
  include JoobQ::Job
  @queue = "receipts"
  getter order_id : Int64
  getter total_cents : Int32

  def initialize(@order_id : Int64, @total_cents : Int32)
  end

  def perform
    puts ReceiptSummary.call(order_id, total_cents)
  end
end

# The business operation can be checked without starting a worker.
raise "Unexpected receipt" unless ReceiptSummary.call(42_i64, 2500) == "Order 42: 2500 cents"
JoobQ.configure do |config|
  config.rest_api_enabled = false
  queue "receipts", 1, SummarizeReceiptJob
end
SummarizeReceiptJob.enqueue(order_id: 42_i64, total_cents: 2500)
JoobQ.forge
```
{% endcode %}

Run `crystal run src/receipt_worker.cr`; expect `Order 42: 2500 cents`, then stop it with Ctrl-C. The example checks the business function before starting Redis-backed processing.

In a deployed application, keep producer calls such as `enqueue` outside the worker startup file. Put business operations in application services, registration in an initializer, and startup/shutdown in the worker entry point.

For real receipts, pass a record ID and a versioned business key. Let the service load the data it needs and enforce idempotency at the database or provider boundary. Do not serialize credentials or open connections into jobs.

**Next:** [Transactional outbox](transactional-outbox.md).
