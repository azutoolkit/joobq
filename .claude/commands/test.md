---
description: Run JoobQ test suite with various options
---

# Run Tests

Execute the JoobQ test suite.

## Commands

```bash
# Run all tests
crystal spec

# Run specific test file
crystal spec spec/{filename}_spec.cr

# Run specific test by line number
crystal spec spec/{filename}_spec.cr:{line}

# Run with verbose output
crystal spec --verbose

# Run tests matching pattern
crystal spec --example "job enqueue"
```

## Prerequisites

Ensure Redis is running:

```bash
docker-compose up -d
```

Or manually:

```bash
redis-server
```

## Test Environment

Tests use `JOOBQ_ENV=test` which loads `config/joobq.test.yml`.

## Common Test Files

| File | Purpose |
|------|---------|
| `spec/job_spec.cr` | Job module tests |
| `spec/queue_spec.cr` | Queue operations |
| `spec/worker_spec.cr` | Worker processing |
| `spec/middleware_spec.cr` | Middleware pipeline |
| `spec/retry_refactor_spec.cr` | Retry logic |
| `spec/error_monitor_spec.cr` | Error tracking |
| `spec/yaml_config_spec.cr` | Configuration loading |
| `spec/api_endpoints_spec.cr` | REST API tests |

## Test Helpers

Available test jobs from `spec/helpers/all_test_jobs.cr`:
- `Job1` - Simple job
- `ExampleJob` - Job with arguments
- `FailJob` - Always fails
- `RetryTestJob` - For retry testing
