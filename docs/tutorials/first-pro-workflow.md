---
description: Run one activity through the Pro workflow engine and read its result.
---

# Your first Pro workflow

*Tutorial · Pro*

You will define a one-step workflow, start a run for order 42, and print the run's result. You need Crystal 1.22 or newer, a Redis server on `localhost:6379`, and read access to the `azutoolkit/joobq-pro` repository.

{% stepper %}
{% step %}
## Create the project

```sh
mkdir -p order_workflow/src
cd order_workflow
```

{% code title="shard.yml" %}
```yaml
name: order_workflow
version: 0.1.0

dependencies:
  joobq_pro:
    github: azutoolkit/joobq-pro
    version: "= 0.2.4"
```
{% endcode %}

```sh
shards install
```

You should see `joobq` installed with it:

```
I: Resolving dependencies
I: Fetching https://github.com/azutoolkit/joobq-pro.git
I: Fetching https://github.com/azutoolkit/joobq.git
I: Fetching https://github.com/stefanwille/crystal-redis.git
I: Fetching https://github.com/kostya/cron_parser.git
I: Fetching https://github.com/ysbaddaden/pool.git
I: Installing pool (0.2.4)
I: Installing redis (2.9.1)
I: Installing cron_parser (0.4.0)
I: Installing joobq (0.5.6)
I: Installing joobq_pro (0.2.4)
I: Writing shard.lock
```
{% endstep %}

{% step %}
## Write the workflow

Create `src/workflow.cr`:

{% code title="src/workflow.cr" %}
<!-- example: pro/first_workflow.cr -->
```crystal
require "joobq_pro"
include JoobQPro::Workflows::DSL

struct OrderInput
  include JSON::Serializable
  getter order_id : Int64
end

class ProcessOrder
  def perform(input : OrderInput, context : JoobQPro::Workflows::ActivityContext) : String
    "Processed order #{input.order_id}"
  end
end

ProcessOrderWorkflow = workflow "process-order", timeout: 1.minute do
  step :process, ProcessOrder
end

JoobQ.configure { |config| config.rest_api_enabled = false }
worker = JoobQPro::Workflows::Worker.new(activity_workers: 1, orchestrators: 1, scheduler: false)
begin
  worker.register(ProcessOrderWorkflow).start
  id = worker.client.start("process-order", {order_id: 42_i64})
  result = worker.client.result(id, timeout: 10.seconds)
  raise "Unexpected workflow result" unless result["process"].as_s == "Processed order 42"
  puts result["process"].as_s
ensure
  JoobQPro.shutdown
  JoobQ.shutdown
end
```
{% endcode %}

`ProcessOrder` is the activity; the `workflow` block declares one step, `:process`, that runs it with the run's input.
{% endstep %}

{% step %}
## Run it

```sh
crystal run src/workflow.cr
```

Without a `JOOBQ_PRO_LICENSE`, Pro first prints a licence warning. Then you should see:

```
Processed order 42
```

The program started the run, waited for its result, and shut down Pro and then Core.
{% endstep %}
{% endstepper %}

You have run an activity through the workflow engine: the run's steps were recorded in Redis, and `result` read the step's output back.

## Next steps

- [Build a parallel workflow with the DSL](parallel-workflow-dsl.md): two branches and a join.
- [Workflows and sagas](../explanation/durable-workflows.md): history, compensation and scopes.
- [Build and run workflows](../how-to/build-and-run-workflows.md): run a workflow worker in your application.
