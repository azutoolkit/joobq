---
description: The public Crystal API of JoobQ Core that is frozen for 1.0, what is deprecated, and what is not covered.
---

# Public API

*Reference · Core*

This page is the list the [compatibility policy](compatibility.md) refers to. A member in a table below is **frozen**: within a major version its name, argument names, argument types and return type do not change, and it is not removed. Anything not listed here is not frozen, whether or not it is public in the source. The details of each member are on [Core API](core-api.md) and [Configuration](configuration.md). A spec (`spec/public_surface_spec.cr`) fails when a member listed here does not exist.

Before 1.0 the freeze is a promise about the shape of 1.0: a 0.x release may still change a frozen member, and says so in the changelog under **Changed (breaking)**.

## Defining and enqueuing jobs

`Job` stands for any class or struct that includes `JoobQ::Job`.

| Member | Use |
| --- | --- |
| `Job.enqueue` | Build the job from keyword arguments and push it to its queue; returns the `jid` |
| `Job.batch_enqueue` | Push an array of jobs in pipelined batches |
| `Job.delay` | One job, due after a `Time::Span` (`for:`); returns the `jid` |
| `Job.schedule` | Run `perform` every span in this process, without a queue |
| `Job.perform` | Run the job now, in this process |
| `Job#perform` | The method you implement |
| `Job#jid` | The job's `UUID` |
| `Job#queue` | Queue name |
| `Job#retries` | Retries left |
| `Job#max_retries` | Retry limit |
| `Job#expires` | Expiry, Unix milliseconds |
| `Job#status` | `Job::Status`: `Completed`, `Dead`, `Enqueued`, `Expired`, `Retrying`, `Running`, `Scheduled` |
| `Job#error` | The last failure record, `nil` if none |
| `Job#past_expiration?` | True once `expires` has passed |

`JoobQ::NonRetryableError` (raise it to dead-letter without retrying), `JoobQ::UnknownQueue` and the `encrypted_property` macro are frozen too.

## The `JoobQ` module

| Member | Use |
| --- | --- |
| `JoobQ.configure` | Yields the configuration |
| `JoobQ.config` | The `JoobQ::Configure` in effect |
| `JoobQ.initialize_config` | Load the YAML configuration found by the search order in [Configuration](configuration.md) |
| `JoobQ.initialize_config_with` | Load it from a given source: `:file`, `:yaml`, `:string`, `:sources`, `:cli_args`, `:env_overrides` or `:hybrid` |
| `JoobQ.set_config` | Install a `JoobQ::Configure` you built |
| `JoobQ.forge` | Start schedulers, queues and the management API; handles signals |
| `JoobQ.shutdown` | Stop gracefully |
| `JoobQ.abandoned_jobs` | Jobs put back by the last shutdown |
| `JoobQ.enqueue` | Enqueue a job instance, or raw JSON on a named queue |
| `JoobQ.queues` | The queue registry |
| `JoobQ.[]` | One queue by name |
| `JoobQ.store` | The configured `JoobQ::Store` |
| `JoobQ.error_monitor` | The configured `JoobQ::ErrorMonitor` |

`JoobQ::EXIT_CLEAN` and `JoobQ::EXIT_ABANDONED` are frozen.

## Queues and dead letters

| Member | Use |
| --- | --- |
| `JoobQ::Queue#pause!` | Pause the queue for every process |
| `JoobQ::Queue#resume!` | Resume it |
| `JoobQ::Queue#paused?` | Whether it is paused |
| `JoobQ::Queue#resize` | Set this process's worker count |
| `JoobQ::Queue#size` | Waiting jobs |
| `JoobQ::Queue#clear` | Delete the waiting jobs |
| `JoobQ::Queue#stop!` | Stop this process's workers |
| `JoobQ::Queue#name` | Queue name |
| `JoobQ::Queue#job_type` | Job class name |
| `JoobQ::Queue#total_workers` | Configured workers |
| `JoobQ::Queue#running_workers` | Running workers |
| `JoobQ::Queue#throttle_limit` | The throttle, if any |
| `JoobQ::DeadLetterQueue#count` | Dead letters, overall or per queue |
| `JoobQ::DeadLetterQueue#counts` | Per-queue counts |
| `JoobQ::DeadLetterQueue#page` | One page of entries |
| `JoobQ::DeadLetterQueue#find` | One entry by `jid` |
| `JoobQ::DeadLetterQueue#redrive` | Put entries back on their queue |
| `JoobQ::DeadLetterQueue#purge` | Delete entries |
| `JoobQ::DeadLetterQueue#purge_all` | Delete all, or all of one queue |

## Configuration

Every property in the table of [Configuration](configuration.md) is frozen, with its type and default behavior (a default may change in a major version, or earlier with a changelog entry that says **breaking**). The ones the spec checks:

| Member | Use |
| --- | --- |
| `JoobQ::Configure#default_queue` | Queue for jobs that name none |
| `JoobQ::Configure#retries` | Default retries |
| `JoobQ::Configure#expires` | Default job lifetime |
| `JoobQ::Configure#timeout` | Default timeout |
| `JoobQ::Configure#dead_letter_ttl` | Dead letter retention |
| `JoobQ::Configure#worker_batch_size` | Jobs a worker holds at once |
| `JoobQ::Configure#rest_api_enabled?` | Management API on or off |
| `JoobQ::Configure#time_location` | Zone of cron patterns |
| `JoobQ::Configure#middlewares` | The middleware list |
| `JoobQ::Configure#store` | The store |
| `JoobQ::Configure#payload_encryption` | Keys for `encrypted_property` |
| `JoobQ::Configure#allow_plaintext_payloads?` | Whether workers accept unsealed values |
| `JoobQ::Configure#redact_api_payloads?` | Whether the management API hides secret-named arguments |
| `JoobQ::Configure#redacted_payload_keys` | The names it hides |
| `JoobQ::Configure#scheduler` | Scheduler DSL block |
| `JoobQ::Configure#error_monitoring` | Error monitor settings |

The block macros `queue name, workers, JobClass, throttle` and `register_job JobClass` are frozen. YAML keys and `JOOBQ_*`/`REDIS_*` variables are listed in [Configuration](configuration.md) and covered by the same policy.

## Operations

| Member | Use |
| --- | --- |
| `JoobQ::WorkerRegistry#start` | Publish worker heartbeats |
| `JoobQ::Events.subscribe` | Receive lifecycle events |
| `JoobQ::ManagementPolicy.from_env` | Management API tokens from the environment |

The HTTP management routes, their roles and their JSON shapes ([Core API](core-api.md)), the `joobq:v1:` Redis keyspace and the stored job format (`"v": 1`) are frozen as well.

## Deprecated

Still callable; the compiler warns at each call site. Removed no sooner than the rule on the [compatibility page](compatibility.md) allows.

| Member | Use instead |
| --- | --- |
| `JoobQ.add` | `JoobQ.enqueue(job)` |
| `Job.enqueue_at` | `Job.delay(for: span, ...)` |
| `JoobQ.load_from_yaml`, `JoobQ.load_hybrid`, `JoobQ.load_from_yaml_sources`, `JoobQ.load_from_cli_args`, `JoobQ.load_auto`, `JoobQ.load_from_file`, `JoobQ.load_from_string`, `JoobQ.load_with_env_overrides`, `JoobQ.find_config_file` | `JoobQ.initialize_config` or `JoobQ.initialize_config_with` |
| `POST /joobq/jobs` | `Job.enqueue`, or `JoobQ.enqueue(queue, json)` |

## Not covered

- **Preview:** `JoobQ::Delivery::Runtime` and the rest of `JoobQ::Delivery`, and the workflow pages of JoobQ Pro marked Preview.
- **Internal:** anything marked `:nodoc:` in the source or absent from this page, among them `JoobQ.reset_config`, `JoobQ::MiddlewarePipeline`, `JoobQ::RedisStore#redis`, `JoobQ::YamlConfigLoader`, `JoobQ::Configure.load_*`, `Job#__secret_values` and everything in `JoobQ::Keys` beyond the key layout. JoobQ Pro and JoobQUI use some of these today and ship with the matching JoobQ version.
- **Engine integration:** `JoobQ::Store`, `JoobQ::RedisStore`, `JoobQ::BaseQueue`, `JoobQ::QueueFactory` and the classes JoobQ Pro and JoobQUI build on are not frozen for third parties yet; they are reviewed separately.
- Pro: [Pro API](pro-api.md) has its own status.

## See also

- [Compatibility and support policy](compatibility.md)
- [Core API](core-api.md)
- [Configuration](configuration.md)
