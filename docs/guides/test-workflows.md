---
description: Test business behavior, graph structure, and real worker execution separately.
---

# Test workflows

A useful test tells you which boundary broke. Keep three layers: business logic without Redis, the workflow graph without workers, and execution against an isolated Redis instance.

## Check the graph

Suppose `src/workflows/checkout.cr` exports the `Checkout` blueprint from the [ordering example](../pro/workflow-dsl/reference.md#order-and-parallel-branches). It should declare the workflow without starting a worker or enqueueing anything.

<!-- illustrative: a spec for the checkout graph shown in the DSL reference -->
```crystal
require "spec"
require "../src/workflows/checkout"

describe "Checkout ordering" do
  it "joins the receipt and shipping branches" do
    definition = Checkout.definition
    definition.step("ship").depends_on.should eq(["pack"])
    definition.step("complete").depends_on.should eq(["receipt", "ship"])
  end
end
```

Run it with `crystal spec spec/checkout_spec.cr`. Blueprint construction validates graph references and activity contracts; it does not validate every possible JSON payload. Test old queued input shapes as well as today's happy path.

## Exercise the worker

Use a dedicated Redis instance and the same locked dependencies as deployment. Cover success, a transient retry, permanent failure, compensation, signal timeout, and restart while work is waiting. Assert the business effect and final workflow outcome, not only an empty queue.

From the JoobQ repository, the documented Pro fixtures run with:

```sh
cd examples/docs/pro
shards install --frozen
cd ../../..
python3 scripts/test_docs_examples.py --edition pro
```

The runner starts disposable Redis, bounds runtime/output, and tears down its processes. The production-worker fixture receives SIGTERM and must exit cleanly. These examples are smoke tests; add your real activity behavior and deployment failure scenarios before rollout.

**Next:** [Deploy workers](../production-deployment/deploy-workers.md).
