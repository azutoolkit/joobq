---
description: The diagnostic codes JoobQ Core puts at the end of its own error messages, with what each means and what to do.
---

# Error codes

*Reference · Core*

JoobQ's own errors end their message with a code and the address of its page, for example
`Configuration file not found: /app/joobq.yml [JQ-102] https://joobq.io/errors/JQ-102`. A message that wraps another
error keeps the inner code too: the code at the end is the error raised, the one inside is its cause. Codes are
permanent: a code is never renumbered or reused. `JoobQ::ErrorCodes.all` (and `.to_json`) is the catalog this page
is copied from, and `error.as(JoobQ::Coded).joobq_error_code` gives the entry of a raised error.

Ranges: JQ-1xx configuration, JQ-2xx Redis and storage, JQ-3xx jobs and queues, JQ-4xx payload encryption, JQ-5xx
management API (no codes yet).

| Code | Title | What it means | What to do |
| --- | --- | --- | --- |
| [JQ-101](https://joobq.io/errors/JQ-101) | Configuration not initialized | JoobQ.config was read while no configuration was set, for example right after JoobQ.reset_config. | Set the configuration before using JoobQ: JoobQ.configure, JoobQ.set_config or one of the JoobQ.initialize_config loaders. |
| [JQ-102](https://joobq.io/errors/JQ-102) | Configuration file not found | The YAML configuration file given to the loader does not exist or could not be read. | Check the path (a relative one is expanded from the working directory); load_from_file reports a missing file as JQ-105 with this code inside its message. |
| [JQ-103](https://joobq.io/errors/JQ-103) | Invalid YAML syntax | The configuration text is not valid YAML, so nothing in it was applied. | Fix the YAML at the line and column the message gives (indentation, quotes, a missing colon). |
| [JQ-104](https://joobq.io/errors/JQ-104) | Invalid configuration value | A setting is missing or out of range: a YAML key the schema requires, a value of the wrong type, or a Configure setting (retries, timeouts, batch sizes, TTLs) outside its allowed range. | Correct the setting the message names to the range it states; a job class must also be registered with QueueFactory.register_job_type before a queue names it. |
| [JQ-105](https://joobq.io/errors/JQ-105) | Configuration could not be loaded | Loading or mapping a configuration file or text failed; the message carries the underlying error. | Read the cause in the message (it may carry its own JQ code) and fix the file, the path or the Redis settings it names. |
| [JQ-201](https://joobq.io/errors/JQ-201) | Redis is not durable enough for the durable runtime | The durable delivery runtime refuses a Redis that could lose acknowledged writes or evict keys. | Configure Redis with appendonly yes, appendfsync always and maxmemory-policy noeviction, or build the runtime with production: false outside production. |
| [JQ-301](https://joobq.io/errors/JQ-301) | Job class not registered | A queue was requested for a job class that QueueFactory does not know, so the queue cannot be created. | Call QueueFactory.register_job_type(YourJob) before the queue is created, and use the exact class name in the YAML job_class. |
| [JQ-302](https://joobq.io/errors/JQ-302) | Job failed and must not be retried | The job raised NonRetryableError (or a subclass): running it again cannot succeed, so it goes to the dead letter queue whatever retries it has left. | Fix the cause the message names (bad input, a missing record), then enqueue a new job or retry it from the dead letter queue. |
| [JQ-401](https://joobq.io/errors/JQ-401) | Sealed payload value cannot be opened | A value of an encrypted job property is not sealed, was sealed with a key that is not configured, is damaged, or fails authentication. | Configure every key the stored jobs were sealed with (old keys open, the first one seals); a job that still cannot be opened was altered or belongs to another class or property. |
| [JQ-402](https://joobq.io/errors/JQ-402) | Payload encryption keys missing or malformed | No payload key is configured, or a key is not 32 bytes in 64 hex digits or base64, a key id is not 1 to 16 of a-z 0-9 _ -, or an id appears twice. | Set payload_encryption in JoobQ.configure, or JOOBQ_PAYLOAD_KEYS / JOOBQ_PAYLOAD_KEY, to valid id:key entries; workers keep such jobs queued until the keys are fixed. |

| Code | Raised as |
| --- | --- |
| JQ-101 | `JoobQ::ConfigNotInitializedError` |
| JQ-102 | `JoobQ::ConfigFileNotFoundError` |
| JQ-103 | `JoobQ::ConfigParseError` |
| JQ-104 | `JoobQ::ConfigValidationError` |
| JQ-105 | `JoobQ::ConfigLoadError` |
| JQ-201 | `ArgumentError` from `JoobQ::Delivery::Runtime.new` (`production: true`) |
| JQ-301 | `JoobQ::QueueFactoryError` |
| JQ-302 | `JoobQ::NonRetryableError` and its subclasses (the message is yours and is left as raised; read the code with `joobq_error_code`) |
| JQ-401 | `JoobQ::Encryption::Error` and `Encryption::PlaintextRefused` |
| JQ-402 | `JoobQ::Encryption::ConfigurationError` |
