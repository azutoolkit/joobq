# JoobQ YAML Configuration

JoobQ now supports YAML configuration files for declarative job queue setup. This allows you to configure queues, middlewares, schedulers, and other settings through YAML files instead of imperative Crystal code.

## Quick Start

### 1. Create a Configuration File

Create `config/joobq.yml` (or `config/joobq.development.yml` for environment-specific config):

```yaml
joobq:
  settings:
    default_queue: "default"
    retries: 3
    timeout: "30 seconds"
    timezone: "America/New_York"

  queues:
    email:
      job_class: "EmailJob"
      workers: 5
      throttle:
        limit: 10
        period: "1 minute"

    image:
      job_class: "ImageProcessingJob"
      workers: 3

  middlewares:
    - type: "throttle"
    - type: "retry"
    - type: "timeout"

  error_monitoring:
    alert_thresholds:
      error: 10
      warn: 50
    time_window: "5 minutes"

  features:
    rest_api: true
    stats: true
```

### 2. Load Configuration in Your Application

```crystal
require "joobq"

# Auto-discovery (finds config files automatically)
config = JoobQ::YamlConfigLoader.load_auto
JoobQ.configure = config

# Or use the Configure class
config = JoobQ::Configure.load_from_yaml
JoobQ.configure = config
```

### 3. Start JoobQ

```crystal
JoobQ.forge
```

## Configuration File Discovery

JoobQ automatically searches for configuration files in this order:

1. **Environment-specific files** (highest priority):

   - `./config/joobq.development.yml`
   - `./config/joobq.production.yml`
   - `./config/joobq.test.yml`

2. **Standard locations**:

   - `./joobq.yml`
   - `./config/joobq.yml`
   - `./config/joobq.yaml`
   - `./joobq.yaml`

3. **Environment variables**:

   - `JOOBQ_CONFIG_PATH` or `JOOBQ_CONFIG_FILE`

4. **System locations**:
   - `~/.joobq/joobq.yml`
   - `/etc/joobq/joobq.yml`

## Configuration Options

### Settings

```yaml
joobq:
  settings:
    default_queue: "default" # Default queue name
    retries: 3 # Number of retries for failed jobs
    timeout: "30 seconds" # Job timeout
    expires: "7 days" # Job expiration time
    failed_ttl: "1 hour" # Failed job TTL
    dead_letter_ttl: "30 days" # Dead letter queue TTL
    worker_batch_size: 10 # Worker batch size
    timezone: "America/New_York" # System timezone
```

### Queues

```yaml
joobq:
  queues:
    queue_name:
      job_class: "JobClassName" # Job class to process
      workers: 5 # Number of workers
      throttle: # Optional throttling
        limit: 10 # Jobs per period
        period: "1 minute" # Time period
```

### Middlewares

```yaml
joobq:
  middlewares:
    - type: "throttle" # Throttle middleware
    - type: "retry" # Retry middleware
    - type: "timeout" # Timeout middleware
```

### Error Monitoring

```yaml
joobq:
  error_monitoring:
    alert_thresholds:
      error: 10 # Error threshold
      warn: 50 # Warning threshold
      info: 100 # Info threshold
    time_window: "5 minutes" # Time window for counting
    max_recent_errors: 100 # Max errors to keep
```

### Schedulers

```yaml
joobq:
  schedulers:
    - timezone: "UTC" # Scheduler timezone
      cron_jobs: # Cron-based jobs
        - pattern: "0 */6 * * *" # Cron pattern
          job: "CleanupJob" # Job class
          args: # Job arguments
            cleanup_type: "logs"
      recurring_jobs: # Interval-based jobs
        - interval: "5 minutes" # Job interval
          job: "HealthCheckJob" # Job class
          args: {} # Job arguments
```

### Redis Configuration

```yaml
joobq:
  redis:
    host: "localhost" # Redis host
    port: 6379 # Redis port
    password: "secret" # Redis password (optional)
    pool_size: 500 # Connection pool size
    pool_timeout: 2.0 # Pool timeout in seconds
```

### Pipeline Optimization

```yaml
joobq:
  pipeline:
    batch_size: 100 # Batch size for operations
    timeout: 1.0 # Pipeline timeout
    max_commands: 1000 # Max commands per pipeline
```

### Features

```yaml
joobq:
  features:
    rest_api: true # Enable REST API
    stats: true # Enable statistics
```

## Environment Variable Overrides

All configuration values can be overridden via environment variables:

```bash
export JOOBQ_DEFAULT_QUEUE="priority"
export JOOBQ_RETRIES="5"
export JOOBQ_TIMEOUT="60 seconds"
export JOOBQ_TIMEZONE="America/Los_Angeles"
export JOOBQ_PIPELINE_BATCH_SIZE="200"
export JOOBQ_REST_API_ENABLED="true"
```

## Advanced Usage

### Multiple Configuration Sources

```crystal
# Load from multiple files and merge them
config = JoobQ::YamlConfigLoader.load_from_sources([
  "./config/joobq.base.yml",
  "./config/joobq.development.yml",
  "./config/joobq.local.yml"
])
```

### Hybrid Configuration (YAML + Code)

```crystal
# Load YAML config and apply programmatic overrides
config = JoobQ::Configure.load_hybrid do |cfg|
  cfg.retries = 10
  cfg.use do |middlewares|
    middlewares << MyCustomMiddleware.new
  end
end
```

### CLI Integration

```bash
# Load specific config file
joobq --config ./my-config.yml

# Load environment-specific config
joobq --env production

# Combine both
joobq -c ./config/joobq.yml -e staging
```

### Environment-Specific Loading

```crystal
# Load configuration for specific environment
config = JoobQ::YamlConfigLoader.load_with_env_overrides(env: "production")
```

## Time Span Formats

Time spans can be specified in various formats:

- `"5 seconds"` or `"5 second"`
- `"2 minutes"` or `"2 minute"`
- `"1 hour"` or `"1 hour"`
- `"3 days"` or `"3 day"`
- `"1 week"` or `"1 week"`
- `"500 milliseconds"` or `"500 millisecond"`

## Cron Patterns

Cron patterns follow the standard 5-field format:

```
minute hour day month weekday
*     *    *   *     *
```

Examples:

- `"0 */6 * * *"` - Every 6 hours
- `"0 0 * * *"` - Daily at midnight
- `"*/15 * * * *"` - Every 15 minutes

## Error Handling

The YAML configuration system provides comprehensive error handling:

### File Not Found

```crystal
begin
  config = JoobQ::YamlConfigLoader.load_from_file("missing.yml")
rescue JoobQ::ConfigFileNotFoundError
  puts "Configuration file not found, using defaults"
  config = JoobQ::Configure.new
end
```

### Invalid YAML

```crystal
begin
  config = JoobQ::YamlConfigLoader.load_from_string(invalid_yaml)
rescue JoobQ::ConfigParseError => ex
  puts "YAML parsing failed: #{ex.message}"
end
```

### Validation Errors

```crystal
begin
  config = JoobQ::YamlConfigLoader.load_auto
rescue JoobQ::ConfigValidationError => ex
  puts "Configuration validation failed: #{ex.message}"
end
```

## Migration from Programmatic Configuration

### Before (Programmatic)

```crystal
JoobQ.configure do |config|
  config.queue("email", 5, EmailJob, {limit: 10, period: 1.minute})
  config.retries = 3
  config.timeout = 30.seconds
  config.rest_api_enabled = true

  config.scheduler do
    cron("0 */6 * * *") do
      CleanupJob.enqueue
    end
  end
end
```

### After (YAML)

```yaml
# config/joobq.yml
joobq:
  settings:
    retries: 3
    timeout: "30 seconds"

  queues:
    email:
      job_class: "EmailJob"
      workers: 5
      throttle:
        limit: 10
        period: "1 minute"

  schedulers:
    - cron_jobs:
        - pattern: "0 */6 * * *"
          job: "CleanupJob"

  features:
    rest_api: true
```

## Example Files

See the `config/` directory for example configuration files:

- `config/joobq.development.yml` - Development configuration
- `config/joobq.production.yml` - Production configuration
- `config/joobq.test.yml` - Test configuration
- `config/joobq.base.yml` - Base configuration for merging

## Running the Example

```bash
# Run the YAML configuration example
crystal run examples/yaml_config_example.cr

# Run tests
crystal spec spec/yaml_config_spec.cr
```

## Benefits

1. **Declarative Configuration**: Define your job queue setup in YAML
2. **Environment-Specific**: Different configs for development, production, test
3. **Environment Overrides**: Override any setting via environment variables
4. **Multiple Sources**: Merge configurations from multiple files
5. **Validation**: Comprehensive schema validation with helpful error messages
6. **Backward Compatible**: Existing programmatic configuration still works
7. **Flexible Discovery**: Automatic file discovery with multiple fallback locations

## Troubleshooting

### Configuration Not Loading

- Check file permissions and paths
- Verify YAML syntax is valid
- Use `YamlConfigLoader.find_config_file` to see which file would be loaded

### Validation Errors

- Check that all required fields are present
- Verify time span formats (e.g., "30 seconds" not "30s")
- Ensure numeric values are within valid ranges
- Check cron patterns have 5 fields

### Job Classes Not Found

- Ensure job classes are defined and available
- Check that job class names in YAML match actual class names
- Make sure job classes include `JoobQ::Job`

For more examples and advanced usage, see `examples/yaml_config_example.cr`.
