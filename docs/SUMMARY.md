# Table of contents

* [Introduction](README.md)

## Tutorials

* [Tutorials](tutorials/README.md)
  * [Your first background job](tutorials/first-background-job.md)
  * [Your first Pro workflow](tutorials/first-pro-workflow.md)
  * [Build a parallel workflow with the DSL](tutorials/parallel-workflow-dsl.md)

## How-to Guides

* [How-to Guides](how-to/README.md)
  * [Install JoobQ and its prerequisites](how-to/install.md)
  * [Use JoobQ in an Azu application](how-to/use-joobq-in-azu.md)
  * [Write and enqueue jobs](how-to/write-and-enqueue-jobs.md)
  * [Delay and schedule jobs](how-to/schedule-jobs.md)
  * [Configure queues and worker counts](how-to/configure-queues.md)
  * [Tune concurrency and shutdown](how-to/tune-concurrency-and-shutdown.md)
  * [Set retries and handle failures](how-to/handle-failures.md)
  * [Configure an application](how-to/configure-an-application.md)
  * [Connect to Redis](how-to/connect-to-redis.md)
  * [Run workers](how-to/run-workers.md)
  * [Use clients and producers](how-to/use-clients-and-producers.md)
  * [Write idempotent jobs](how-to/write-idempotent-jobs.md)
  * [Keep jobs thin](how-to/thin-jobs.md)
  * [Enqueue from a transactional outbox](how-to/transactional-outbox.md)
  * [Add Pro to an existing application](how-to/add-pro.md)
  * [Rate-limit a job class](how-to/rate-limit-a-job-class.md)
  * [Run cron and recurring jobs](how-to/run-cron-and-recurring-jobs.md)
  * [Build and run workflows](how-to/build-and-run-workflows.md)
  * [Wait for approval](how-to/wait-for-approval.md)
  * [Fan out and join](how-to/fan-out-and-join.md)
  * [Compensate with a saga](how-to/sagas-and-compensation.md)
  * [Test workflows](how-to/test-workflows.md)
  * [Migrate to the workflow DSL](how-to/migrate-to-the-workflow-dsl.md)
  * [Pause queues during an outage](how-to/pause-queues-during-an-outage.md)
  * [Deploy and scale workers](how-to/deploy-workers.md)
  * [Prepare a cloud deployment](how-to/prepare-a-cloud-deployment.md)
  * [Deploy on Kubernetes](how-to/deploy-on-kubernetes.md)
  * [Set up Redis and recovery](how-to/redis-and-recovery.md)
  * [Operate and upgrade](how-to/operate-and-upgrade.md)
  * [Recover and migrate](how-to/recover-and-migrate.md)
  * [Measure performance](how-to/measure-performance.md)
  * [Troubleshoot](how-to/troubleshoot.md)
  * [Secure management access](how-to/secure-management-access.md)

## Reference

* [Reference](reference/README.md)
  * [Compatibility](reference/compatibility.md)
  * [Open Source vs Pro vs JoobQUI feature matrix](reference/feature-matrix.md)
  * [Configuration](reference/configuration.md)
  * [Core API](reference/core-api.md)
  * [Pro API](reference/pro-api.md)
  * [Workflow DSL](reference/workflow-dsl.md)
  * [Workflow lifecycle controls](reference/workflow-lifecycle-controls.md)
  * [Azu CLI and terminal dashboard](reference/azu-cli-and-terminal.md)

## Explanation

* [Explanation](explanation/README.md)
  * [Why JoobQ](explanation/why-joobq.md)
  * [Architecture at a glance](explanation/application-architecture.md)
  * [Open Source vs Pro vs JoobQUI](explanation/pro-features.md)
  * [Jobs and payloads](explanation/job-lifecycle.md)
  * [Queues and priorities](explanation/queues-and-workers.md)
  * [Workers and concurrency](explanation/workers-and-concurrency.md)
  * [Retries, backoff and the DLQ](explanation/retries-and-dead-letters.md)
  * [Cron and recurring jobs](explanation/delayed-and-recurring-jobs.md)
  * [Rate limiting and throttling](explanation/rate-limiting-and-throttling.md)
  * [Reliability and recovery](explanation/reliability-and-recovery.md)
  * [Workflows and sagas](explanation/durable-workflows.md)
  * [Batches and unique jobs](explanation/distributed-coordination.md)
  * [Delivery](explanation/delivery.md)
  * [Live observability and metrics](explanation/metrics-and-observability.md)

## Maintainers

* [Documentation validation](validation.md)
* [Automatic releases](releasing.md)
