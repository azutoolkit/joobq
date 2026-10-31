---
description: Run a separate worker service with explicit startup and shutdown ownership.
---

# Deploy workers

Build once from `shard.lock`, then run that binary with environment-specific configuration. Keep producers separate: a worker starting or restarting should not create a new order by itself.

## Own the lifecycle

This complete **Pro v0.2.2** entry point registers a small workflow and waits for SIGTERM or SIGINT. Replace its sample activity with your application code. It does not enqueue work during boot and leaves the management API disabled.

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

```sh
shards install --frozen
mkdir -p bin
crystal build src/worker.cr --release -o bin/worker
CRYSTAL_WORKERS=4 ./bin/worker
```

Choose a thread count appropriate to your allocated CPUs and dependencies. Core-only applications can use `JoobQ.forge`'s built-in signal handling; this Pro entry point owns signal handling itself so Pro stops before Core.

The configured budgets are 20 seconds for Pro, then 10 seconds for Core. Incomplete drain reports a nonzero exit; inspect shutdown logs and abandoned-work counts. A forced kill or Redis outage can prevent a final handoff. Idempotent activity effects remain necessary.

## Check it from a separate producer

With the worker running and the same Redis configuration in another terminal:

{% code title="src/worker_probe.cr" %}
<!-- example: pro/worker_probe.cr -->
```crystal
require "joobq_pro"

# Run separately, after production_worker.cr is ready, against the same Redis.
client = JoobQPro::Workflows::Client.new
id = client.start("orders", 42_i64)
result = client.result(id, timeout: 10.seconds)
raise "Unexpected worker result" unless result["process"].as_s == "Processed order 42"
puts result["process"].as_s
```
{% endcode %}

Run `crystal run src/worker_probe.cr`; expect `Processed order 42`. This checks admission, dispatch, and completion. The worker's startup log alone cannot do that. In production, use a canary activity that is safe to repeat and represents the dependencies you need to monitor.

## Run under a supervisor

For a Linux service installed under `/srv/orders`, provision an `orders` service account and a secret-managed `/etc/orders/worker.env`. Give that file restrictive permissions. This example expects the binary and required shared libraries to be installed already.

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

For containers, use the binary as the exec-form entrypoint and set a termination grace period of at least 45 seconds for these budgets; measure the margin under load. Build for the target OS, libc, and architecture. Keep private dependency credentials out of the runtime image and image layers.

`Worker ready` confirms startup only. Continuous readiness needs worker progress and a representative canary, not just a live process or Redis `PING`.

**Next:** [Redis and recovery](redis-and-recovery.md).
