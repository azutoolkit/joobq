---
description: Install once, configure the features you need, and retain a clear upgrade boundary.
---

# Add Pro to an existing application

Pro is a Crystal shard, not a remote switch that adds code to a running Core-only binary. The current upgrade has four steps: obtain repository access, install the dependency, load it, and configure the feature you want.

## 1. Install the supported pair

Authenticate Git using the credentials provided for your Pro repository access. Keep credentials in your credential manager or CI secrets, not the dependency URL.

{% code title="shard.yml — Pro dependency" %}
```yaml
name: order_worker
version: 0.1.0

dependencies:
  joobq_pro:
    github: azutoolkit/joobq-pro
    version: "= 0.2.0"
```
{% endcode %}

```sh
shards install
```

If your app already declares `joobq`, align it with Pro's exact dependency or remove the redundant direct constraint if your dependency policy permits it. Resolve the graph before changing worker code. Pro's pinned Core revision differs from standalone Core `v0.5.1`. Before upgrading an existing worker, check the [queue-registration differences](compatibility.md#release-specific-integration-notes); a typed queue DSL alone is not started by `forge` in Pro's pinned Core.

## 2. Load Pro and configure your license

<!-- illustrative: insertion into an existing application boot file -->
```crystal
require "joobq_pro"
JoobQPro.init
```

Supply `JOOBQ_PRO_LICENSE` through your runtime secret manager before starting the process. A license key does not grant Git repository access; repository credentials do not activate a runtime license. See [access and tokens](../configuration/access.md).

## 3. Enable one capability

Start with a [small workflow](../quick-start/first-workflow.md) or the [metrics middleware](../pro/observability.md). Loading Pro does not convert existing jobs into workflows or Delivery records. Keep existing queues running on their documented API until you deliberately migrate them.

Rebuild and restart the worker after adding the shard. Test the same locked dependencies in staging and production.

## 4. Make customer activation simple

If you operate a service for customers, you can build Pro into your worker image once and expose your own customer entitlement setting. Check that setting in your application before admitting Pro work. This is an application integration pattern, not a built-in JoobQ tenant/billing API.

Keep customer entitlements separate from the service's Pro license. Disabling a customer feature should stop new admissions while existing work drains; do not delete queues, receipts, or workflow histories. A Core-only deployed binary still needs a rebuild before it can use Pro.

{% hint style="info" %}
There is no documented `azu pro enable` command or runtime plugin downloader in this release. The supported route is the Pro shard plus explicit configuration. This guide does not change commercial terms or promise per-customer licensing behavior.
{% endhint %}

**Next:** [Your first Pro workflow](../quick-start/first-workflow.md).
