---
description: Install Crystal, Redis and the JoobQ shards, and check that each one works.
---

# Install JoobQ and its prerequisites

*How-to · Core · Pro*

## Prerequisites

- Crystal 1.22 or newer and Shards (both `joobq` 0.5.6 and `joobq_pro` 0.2.4 declare `crystal: ">= 1.22.0"`).
- A Redis server your workers can reach. JoobQ connects to `localhost:6379` unless `REDIS_URL` or `REDIS_HOST`/`REDIS_PORT` say otherwise.
- For Pro: read access to the private `azutoolkit/joobq-pro` repository, with Git credentials configured on the machine that runs `shards install`.

## Steps

1. Add Core to `shard.yml`:

   ```yaml
   dependencies:
     joobq:
       github: azutoolkit/joobq
       version: "= 0.5.6"
   ```

   For Pro, add `joobq_pro` instead; it brings the matching `joobq` with it:

   ```yaml
   dependencies:
     joobq_pro:
       github: azutoolkit/joobq-pro
       version: "= 0.2.4"
   ```

2. Install, and commit the resulting `shard.lock`:

   ```sh
   shards install
   ```

3. Point JoobQ at your Redis if it is not on `localhost:6379`:

   ```sh
   export REDIS_URL=redis://redis.internal:6379/0
   ```

## Verify

- `shards install` prints `I: Installing joobq (0.5.6)` (and `I: Installing joobq_pro (0.2.4)` for Pro), then `I: Writing shard.lock`.
- `redis-cli -u "$REDIS_URL" ping` answers `PONG`.
- Run [Your first background job](../tutorials/first-background-job.md): it prints `Processed order 42`.

## See also

- [Compatibility and feature availability](../reference/compatibility.md)
- [Connect to Redis](connect-to-redis.md): TLS, ACL users and pool size.
