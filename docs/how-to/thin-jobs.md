---
description: Keep a job small so its business operation is easy to test and reuse.
---

# Keep jobs thin

*How-to · Core*

## Prerequisites

- A Core project ([Install JoobQ](install.md)).

## Steps

1. Put the business operation in its own class or module that takes plain values and needs no queue.
2. Give the job only the identifiers the operation needs, and call the operation from `perform`.
3. Check the operation directly in a spec or at boot, as the example does before it starts a worker:

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
4. Keep `enqueue` calls in your producers, and `JoobQ.forge` in the worker entry point only.

## Verify

Run `crystal run src/receipt_worker.cr`. It prints `Order 42: 2500 cents`; stop it with Ctrl-C.

## See also

- [Architecture at a glance](../explanation/application-architecture.md)
- [Write idempotent jobs](write-idempotent-jobs.md)
