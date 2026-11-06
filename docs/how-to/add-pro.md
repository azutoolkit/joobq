---
description: Add the Pro shard to an application that already uses JoobQ Core, and switch on one Pro feature.
---

# Add Pro to an existing application

*How-to · Pro*

## Prerequisites

- An application on JoobQ Core 0.5.6.
- Read access to the private `azutoolkit/joobq-pro` repository; keep the Git credentials in your credential manager or CI secrets, not in the dependency URL.
- A Pro licence key for production (`JOOBQ_PRO_LICENSE`). Without one, Pro logs a warning and still works.

## Steps

1. Replace the `joobq` dependency with `joobq_pro`, which requires `joobq >= 0.5.6, < 0.6.0`:

   ```yaml
   dependencies:
     joobq_pro:
       github: azutoolkit/joobq-pro
       version: "= 0.2.4"
   ```

2. Run `shards install` and commit `shard.lock`.
3. Require Pro where you required Core; your job classes and queues stay as they are:

   <!-- illustrative: the application's boot file -->
   ```crystal
   require "joobq_pro"
   ```

4. Give the process its licence key through your secret manager: `JOOBQ_PRO_LICENSE`.
5. Switch on one feature: a [workflow](build-and-run-workflows.md), a [rate limit](rate-limit-a-job-class.md), or the metrics middleware (`config.middlewares.unshift(JoobQPro::Middleware::Metrics.instance)`).
6. On shutdown, stop Pro before Core: `JoobQPro.shutdown`, then `JoobQ.shutdown`.

## Verify

- `shards install` lists `joobq (0.5.6)` and `joobq_pro (0.2.4)`.
- At boot, with no licence key, the log shows `JoobQ Pro is running without a valid license.`; with a valid key it does not.
- Run [Your first Pro workflow](../tutorials/first-pro-workflow.md): it prints `Processed order 42`.

## See also

- [Open Source vs Pro vs JoobQUI](../explanation/pro-features.md)
- [Compatibility and feature availability](../reference/compatibility.md)
