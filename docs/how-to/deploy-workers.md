---
description: Run a separate worker service with explicit startup and shutdown ownership.
---

# Deploy and scale workers

*How-to · Core · Pro*

## Prerequisites

- The worker's code in a project with a committed `shard.lock`; for Pro, read access to the Pro repository at build time.

## Steps

1. Write a worker entry point that registers your workflows, waits for SIGTERM or SIGINT, and stops Pro before Core. It enqueues nothing at boot:

{% code title="src/worker.cr" %}
<!-- example: pro/production_worker.cr -->
```crystal
require "joobq_pro"
include JoobQPro::Workflows::DSL

class ProcessOrder
  def perform(order_id : Int64, context : JoobQPro::Workflows::ActivityContext) : String
    "Processed order #{order_id}"
  end
end

Orders = workflow "orders", timeout: 1.minute do
  step :process, ProcessOrder, timeout: 10.seconds
end

JoobQ.configure { |config| config.rest_api_enabled = false }
stopping = Channel(Nil).new(1)
[Signal::INT, Signal::TERM].each do |signal|
  signal.trap do
    select
    when stopping.send(nil)
    else
      # A stop is already pending; let the shutdown budget finish.
    end
  end
end

worker = JoobQPro::Workflows::Worker.new(activity_workers: 2, orchestrators: 1, scheduler: false)
clean = false
begin
  worker.register(Orders).start
  puts "Worker ready"
  STDOUT.flush
  stopping.receive
ensure
  begin
    clean = JoobQPro.shutdown(20.seconds)
  ensure
    JoobQ.shutdown(10.seconds)
  end
end
exit(clean && JoobQ.abandoned_jobs == 0 ? 0 : 3)
```
{% endcode %}
2. Build it once from the lockfile (this build enables `-Dpreview_mt` so `CRYSTAL_WORKERS` can select threads):

```sh
shards install --frozen
mkdir -p bin
crystal build src/worker.cr --release -Dpreview_mt -o bin/worker
CRYSTAL_WORKERS=4 ./bin/worker
```
3. Run it under a supervisor. For a Linux service under `/srv/orders`, with an `orders` account and a secret-managed `/etc/orders/worker.env` readable only by it:

```ini
[Unit]
Description=Orders JoobQ worker
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=orders
WorkingDirectory=/srv/orders
EnvironmentFile=/etc/orders/worker.env
ExecStart=/srv/orders/bin/worker
Restart=on-failure
RestartSec=5
KillSignal=SIGTERM
TimeoutStopSec=45
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
```
4. For a container, make the binary the exec-form entrypoint and set a termination grace period longer than the shutdown timeouts (here 20 s for Pro, then 10 s for Core): at least 45 seconds.
5. Keep build-time repository credentials out of the runtime image.
6. To scale, add processes; each runs its own workers against the same Redis.

## Verify

With the worker running, run this producer from another terminal with the same Redis settings:

{% code title="src/worker_probe.cr" %}
<!-- example: pro/worker_probe.cr -->
```crystal
require "joobq_pro"

# Run separately, after production_worker.cr is ready, against the same Redis.
client = JoobQPro::Workflows::Client.new
# A fresh canary each invocation; retries within this invocation reuse its ID.
request_id = UUID.random.to_s
id, created = client.try_start("orders", 42_i64, id: request_id)
raise "Expected a new run" unless created
repeated_id, repeated = client.try_start("orders", 42_i64, id: id)
raise "Repeated start created another run" if repeated || repeated_id != id
result = client.result(id, timeout: 10.seconds)
raise "Unexpected worker result" unless result["process"].as_s == "Processed order 42"
puts result["process"].as_s
```
{% endcode %}
`crystal run src/worker_probe.cr` prints `Processed order 42`. On SIGTERM the worker exits `0` after a clean stop and non-zero when Pro reported an incomplete stop or Core abandoned jobs.

## See also

- [Workers and concurrency](../explanation/workers-and-concurrency.md)
- [Deploy on Kubernetes](deploy-on-kubernetes.md)
