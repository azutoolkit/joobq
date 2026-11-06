---
description: Steps for one task each, from installing JoobQ to running it in production.
---

# How-to Guides

Each guide reaches one goal: prerequisites, steps and a check that it worked. The label after each page says which part of JoobQ it applies to: Core, Pro or JoobQUI.

## Getting Started

* [Install JoobQ and its prerequisites](install.md) · Core · Pro
* [Use JoobQ in an Azu application](use-joobq-in-azu.md) · Core

## Core

* [Write and enqueue jobs](write-and-enqueue-jobs.md) · Core
* [Delay and schedule jobs](schedule-jobs.md) · Core
* [Configure queues and worker counts](configure-queues.md) · Core
* [Tune concurrency and shutdown](tune-concurrency-and-shutdown.md) · Core
* [Set retries and handle failures](handle-failures.md) · Core · Pro
* [Configure an application](configure-an-application.md) · Core
* [Connect to Redis](connect-to-redis.md) · Core
* [Run workers](run-workers.md) · Core · Pro
* [Use clients and producers](use-clients-and-producers.md) · Core · Pro
* [Write idempotent jobs](write-idempotent-jobs.md) · Core
* [Keep jobs thin](thin-jobs.md) · Core
* [Enqueue from a transactional outbox](transactional-outbox.md) · Core

## Advanced

* [Add Pro to an existing application](add-pro.md) · Pro
* [Rate-limit a job class](rate-limit-a-job-class.md) · Pro
* [Run cron and recurring jobs](run-cron-and-recurring-jobs.md) · Core
* [Build and run workflows](build-and-run-workflows.md) · Pro
* [Wait for approval](wait-for-approval.md) · Pro
* [Fan out and join](fan-out-and-join.md) · Pro
* [Compensate with a saga](sagas-and-compensation.md) · Pro
* [Test workflows](test-workflows.md) · Pro
* [Migrate to the workflow DSL](migrate-to-the-workflow-dsl.md) · Pro · Preview
* [Operate workflows in production](https://joobq-website.onrender.com/docs/how-to/operate-workflows-in-production) · Pro · JoobQUI
* [Connect SDK workers](https://joobq-website.onrender.com/docs/how-to/connect-your-environment) · JoobQUI

## Production Ops

* [Triage, redrive and export dead letters](https://joobq-website.onrender.com/docs/how-to/triage-and-redrive-dead-letters) · JoobQUI
* [Pause queues during an outage](pause-queues-during-an-outage.md) · Core · JoobQUI
* [Deploy and scale workers](deploy-workers.md) · Core · Pro
* [Prepare a cloud deployment](prepare-a-cloud-deployment.md) · Core · Pro
* [Deploy on Kubernetes](deploy-on-kubernetes.md) · Core · Pro
* [Set up Redis and recovery](redis-and-recovery.md) · Core · Pro
* [Operate and upgrade](operate-and-upgrade.md) · Core · Pro
* [Recover and migrate](recover-and-migrate.md) · Core · Pro
* [Measure performance](measure-performance.md) · Core
* [Troubleshoot](troubleshoot.md) · Core · Pro
* [Secure management access](secure-management-access.md) · Core · Pro
* [Roll out worker builds](https://joobq-website.onrender.com/docs/how-to/zero-downtime-worker-builds) · Pro · JoobQUI
* [Configure RBAC, SSO and MFA](https://joobq-website.onrender.com/docs/how-to/configure-rbac-sso-and-mfa) · JoobQUI
* [Seal sensitive job payloads](https://joobq-website.onrender.com/docs/how-to/seal-sensitive-job-payloads) · Core · JoobQUI
* [Deploy self-hosted JoobQUI](https://joobq-website.onrender.com/docs/how-to/deploy-licensed-self-hosted) · JoobQUI
* [Get a licence and connect your deployment](https://joobq-website.onrender.com/docs/how-to/get-a-licence-and-connect) · JoobQUI
