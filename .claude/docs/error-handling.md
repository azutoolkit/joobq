# JoobQ Error Handling

## ErrorContext Class

```crystal
ErrorContext.from_exception(
  job: job,
  queue: queue,
  exception: ex,
  worker_id: "worker-123",
  retry_count: 1
)
```

## Error Classification

| Classification | Exception Types |
|----------------|-----------------|
| `validation_error` | ArgumentError |
| `connection_error` | Socket::ConnectError, Redis::CannotConnectError |
| `timeout_error` | IO::TimeoutError |
| `serialization_error` | JSON::Error |
| `configuration_error` | KeyError |
| `unknown_error` | Default |

## Error Monitoring

```crystal
JoobQ.configure do
  error_monitoring do |monitor|
    monitor.alert_thresholds = {"error" => 10, "warn" => 50}
    monitor.time_window = 5.minutes
    monitor.notify_alert = ->(context : Hash(String, String)) {
      SlackNotifier.send(message: context["message"])
    }
  end
end

# Query errors
JoobQ.error_monitor.get_error_stats
JoobQ.error_monitor.get_recent_errors(limit: 20)
```

## Retry Flow

1. Job fails with exception
2. Retry middleware catches error
3. Decrements `job.retries`
4. If retries > 0: Schedule with exponential backoff
5. If retries == 0: Move to dead letter queue

## Dead Letter Queue

```crystal
# Access via API: GET /joobq/dead_letter
dead_letter = JoobQ::DeadLetterManager.new(store)
dead_letter.list(limit: 50)
dead_letter.retry(job_id)
dead_letter.delete(job_id)
```
