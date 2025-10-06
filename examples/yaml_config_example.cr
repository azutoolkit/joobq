require "../src/joobq"

# Example job classes for demonstration
class EmailJob
  include JoobQ::Job

  property recipient : String
  property subject : String
  property body : String

  def initialize(@recipient : String, @subject : String, @body : String)
  end

  def perform
    puts "Sending email to #{@recipient}: #{@subject}"
    # Simulate email sending
    sleep 0.1
  end
end

class ImageProcessingJob
  include JoobQ::Job

  property image_path : String
  property operation : String

  def initialize(@image_path : String, @operation : String)
  end

  def perform
    puts "Processing image #{@image_path} with operation: #{@operation}"
    # Simulate image processing
    sleep 0.2
  end
end

class CleanupJob
  include JoobQ::Job

  property cleanup_type : String

  def initialize(@cleanup_type : String = "general")
  end

  def perform
    puts "Running cleanup: #{@cleanup_type}"
    # Simulate cleanup
    sleep 0.1
  end
end

class DailyReportJob
  include JoobQ::Job

  property report_type : String

  def initialize(@report_type : String = "daily")
  end

  def perform
    puts "Generating #{@report_type} report"
    # Simulate report generation
    sleep 0.1
  end
end

class HealthCheckJob
  include JoobQ::Job

  def perform
    puts "Running health check"
    # Simulate health check
    sleep 0.05
  end
end

# Example 1: Auto-discovery configuration loading
puts "=== Example 1: Auto-discovery Configuration Loading ==="
begin
  config = JoobQ::YamlConfigLoader.load_auto
  puts "Loaded configuration with default_queue: #{config.default_queue}"
  puts "Retries: #{config.retries}"
  puts "Timeout: #{config.timeout}"
  puts "Queues: #{config.queues.keys.join(", ")}"
rescue ex : JoobQ::ConfigFileNotFoundError
  puts "No YAML configuration found, using defaults"
  config = JoobQ::Configure.new
end

# Example 2: Load from specific file
puts "\n=== Example 2: Load from Specific File ==="
config_file = "config/joobq.development.yml"
if File.exists?(config_file)
  begin
    config = JoobQ::YamlConfigLoader.load_from_file(config_file)
    puts "Loaded configuration from #{config_file}"
    puts "Default queue: #{config.default_queue}"
    puts "Queues configured: #{config.queues.keys.join(", ")}"
  rescue ex
    puts "Error loading configuration: #{ex.message}"
  end
else
  puts "Configuration file #{config_file} not found"
end

# Example 3: Load with environment overrides
puts "\n=== Example 3: Load with Environment Overrides ==="
ENV["JOOBQ_RETRIES"] = "7"
ENV["JOOBQ_DEFAULT_QUEUE"] = "env_override"

begin
  config = JoobQ::YamlConfigLoader.load_with_env_overrides(env: "development")
  puts "Loaded configuration with environment overrides"
  puts "Default queue: #{config.default_queue} (should be 'env_override')"
  puts "Retries: #{config.retries} (should be 7)"
rescue ex
  puts "Error loading configuration with overrides: #{ex.message}"
end

# Example 4: Hybrid configuration (YAML + programmatic)
puts "\n=== Example 4: Hybrid Configuration ==="
begin
  config = JoobQ::Configure.load_hybrid do |cfg|
    # Apply programmatic overrides
    cfg.retries = 5
    cfg.worker_batch_size = 20

    # Add custom middleware
    cfg.use do |middlewares|
      middlewares << JoobQ::Middleware::Throttle.new
      middlewares << JoobQ::Middleware::Retry.new
    end
  end

  puts "Hybrid configuration loaded"
  puts "Retries: #{config.retries} (programmatic override)"
  puts "Worker batch size: #{config.worker_batch_size} (programmatic override)"
  puts "Middlewares: #{config.middlewares.size}"
rescue ex
  puts "Error loading hybrid configuration: #{ex.message}"
end

# Example 5: Multiple source merging
puts "\n=== Example 5: Multiple Source Merging ==="
base_config = "config/joobq.base.yml"
env_config = "config/joobq.development.yml"

sources = [base_config, env_config].select { |f| File.exists?(f) }
if sources.any?
  begin
    config = JoobQ::YamlConfigLoader.load_from_sources(sources)
    puts "Merged configuration from sources: #{sources.join(", ")}"
    puts "Default queue: #{config.default_queue}"
    puts "Expires: #{config.expires}"
    puts "Queues: #{config.queues.keys.join(", ")}"
  rescue ex
    puts "Error loading merged configuration: #{ex.message}"
  end
else
  puts "No source files found for merging"
end

# Example 6: CLI argument parsing
puts "\n=== Example 6: CLI Argument Parsing ==="
# Simulate CLI arguments
cli_args = ["--config", "config/joobq.development.yml", "--env", "development"]

begin
  config = JoobQ::YamlConfigLoader.load_from_cli_args(cli_args)
  puts "Loaded configuration from CLI arguments"
  puts "Default queue: #{config.default_queue}"
  puts "Environment-specific configuration applied"
rescue ex
  puts "Error loading configuration from CLI: #{ex.message}"
end

# Example 7: Configuration validation
puts "\n=== Example 7: Configuration Validation ==="
valid_yaml = <<-YAML
  joobq:
    settings:
      default_queue: "valid_queue"
      retries: 3
      timeout: "30 seconds"
    queues:
      test_queue:
        job_class: "EmailJob"
        workers: 2
YAML

invalid_yaml = <<-YAML
  joobq:
    settings:
      retries: -1  # Invalid: negative retries
    queues:
      "":
        job_class: "EmailJob"
        workers: 0  # Invalid: zero workers
YAML

puts "Testing valid configuration..."
begin
  config = JoobQ::YamlConfigLoader.load_from_string(valid_yaml)
  puts "✓ Valid configuration loaded successfully"
rescue ex
  puts "✗ Valid configuration failed: #{ex.message}"
end

puts "Testing invalid configuration..."
begin
  config = JoobQ::YamlConfigLoader.load_from_string(invalid_yaml)
  puts "✗ Invalid configuration should have failed"
rescue ex : JoobQ::ConfigValidationError
  puts "✓ Invalid configuration correctly rejected: #{ex.message}"
rescue ex
  puts "✗ Unexpected error: #{ex.message}"
end

puts "\n=== YAML Configuration Example Complete ==="
puts "This example demonstrates:"
puts "1. Auto-discovery of configuration files"
puts "2. Loading from specific files"
puts "3. Environment variable overrides"
puts "4. Hybrid YAML + programmatic configuration"
puts "5. Multiple source merging"
puts "6. CLI argument parsing"
puts "7. Configuration validation"
puts "\nSee config/ directory for example YAML files."
