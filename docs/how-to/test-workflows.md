---
description: Test business behavior, graph structure, and real worker execution separately.
---

# Test workflows

*How-to · Pro*

## Prerequisites

- A workflow blueprint in its own file that starts nothing when required, for example `src/workflows/checkout.cr`.

## Steps

1. Test the business logic of each activity without Redis.
2. Test the graph without workers: build the blueprint in a spec and check its steps and dependencies:

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
   Run `crystal spec spec/checkout_spec.cr`.
3. Test execution against a dedicated Redis with the same locked dependencies as production: success, a transient retry, a permanent failure, compensation, a signal timeout, and a restart while work waits. Assert the business effect and the final status.
4. Run the documentation's Pro fixtures the same way from the joobq repository:

```sh
cd examples/docs/pro
shards install --frozen
cd ../../..
python3 scripts/test_docs_examples.py --edition pro
```

## Verify

The spec passes, and every scenario of step 3 ends with the expected status and effect.

## See also

- [Deploy and scale workers](deploy-workers.md)
