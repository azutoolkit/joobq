---
description: Turn on Core's HTTP management API with bearer tokens for the roles you need, and check that each role gets what it should.
---

# Secure management access

*How-to · Core · Pro*

## Prerequisites

- A worker process you start with `JoobQ.forge`.
- A secret manager for the tokens. Pro repository access and `JOOBQ_PRO_LICENSE` are separate credentials; neither grants management access.

## Steps

1. Create one token per role you need, each at least 32 bytes, and give them to the worker process:

   ```sh
   export JOOBQ_API_READER_TOKEN="$(openssl rand -hex 32)"
   export JOOBQ_API_OPERATOR_TOKEN="$(openssl rand -hex 32)"
   # export JOOBQ_API_ADMIN_TOKEN="$(openssl rand -hex 32)"   only if someone must reset or delete
   ```

2. Turn the API on in the worker's configuration (it is off by default):

   <!-- illustrative: inside the worker's JoobQ.configure block -->
   ```crystal
   config.rest_api_enabled = true
   ```

3. Start the worker. `forge` serves the API on `127.0.0.1:8080`; keep it on loopback, or put it behind a TLS proxy that passes the `Authorization` header through.
4. Give clients only the token for their role. A reader may `GET`; an operator may also make other changes; only an admin may `DELETE` or call paths containing `/reset` or `/config`.

## Verify

Against a worker started with a reader and an operator token:

```
curl -s -o /dev/null -w '%{http_code}' -X GET http://127.0.0.1:8080/joobq/health/check  -> 401
curl -s -o /dev/null -w '%{http_code}' -X GET -H "Authorization: Bearer $JOOBQ_API_READER_TOKEN" http://127.0.0.1:8080/joobq/health/check  -> 200
curl -s -o /dev/null -w '%{http_code}' -X GET -H "Authorization: Bearer $JOOBQ_API_READER_TOKEN" http://127.0.0.1:8080/joobq/jobs/registry  -> 200
curl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $JOOBQ_API_READER_TOKEN" http://127.0.0.1:8080/joobq/queues/orders/reprocess  -> 403
curl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $JOOBQ_API_OPERATOR_TOKEN" http://127.0.0.1:8080/joobq/queues/orders/reprocess  -> 200
curl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $JOOBQ_API_OPERATOR_TOKEN" http://127.0.0.1:8080/joobq/pipeline/stats/reset  -> 403
curl -s -o /dev/null -w '%{http_code}' -X GET -H "Authorization: Bearer $JOOBQ_API_READER_TOKEN" http://127.0.0.1:8080/joobq/nope  -> 404
```

Every route, the health check included, needs a token. A worker with the API on and no token, or a token shorter than 32 bytes, stops at boot with `management tokens are required` or `management tokens must be at least 32 bytes`.

## See also

- [Security model](https://joobq-website.onrender.com/docs/explanation/security-audit-and-redaction)
- [Configuration](../reference/configuration.md): every `JOOBQ_*` variable.
