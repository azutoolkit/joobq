#!/usr/bin/env crystal

require "yaml"
require "json"

# Simple OpenAPI 3.0 validation script
# This script validates the OpenAPI specification and provides basic checks

def validate_openapi_spec(file_path : String)
  puts "🔍 Validating OpenAPI specification: #{file_path}"

  begin
    # Read and parse the YAML file
    content = File.read(file_path)
    spec = YAML.parse(content)

    # Basic validation checks
    errors = [] of String
    warnings = [] of String

    # Check required fields
    unless spec["openapi"]?
      errors << "Missing 'openapi' field"
    end

    unless spec["info"]?
      errors << "Missing 'info' field"
    else
      info = spec["info"]
      unless info["title"]?
        errors << "Missing 'info.title' field"
      end
      unless info["version"]?
        errors << "Missing 'info.version' field"
      end
    end

    unless spec["paths"]?
      errors << "Missing 'paths' field"
    else
      paths = spec["paths"]
      if paths.as_h.empty?
        warnings << "No paths defined"
      end
    end

    # Check for required JoobQ endpoints
    required_endpoints = [
      "POST /joobq/jobs",
      "GET /joobq/jobs/registry",
      "GET /joobq/health/check",
      "POST /joobq/queues/{queue_name}/reprocess",
      "GET /joobq/errors/stats",
      "GET /joobq/errors/recent",
      "GET /joobq/errors/by-type",
      "GET /joobq/errors/by-queue"
    ]

    paths = spec["paths"]?
    if paths
      required_endpoints.each do |endpoint|
        method, path = endpoint.split(" ", 2)
        found = false

        paths.as_h.each do |key, value|
          if key.to_s == path
            found = true
            break
          end
        end

        unless found
          errors << "Missing required endpoint: #{endpoint}"
        end
      end
    end

    # Check components
    unless spec["components"]?
      warnings << "No components section defined"
    else
      components = spec["components"]
      unless components["schemas"]?
        warnings << "No schemas defined in components"
      end
    end

    # Report results
    if errors.empty? && warnings.empty?
      puts "✅ OpenAPI specification is valid!"
    else
      unless errors.empty?
        puts "❌ Errors found:"
        errors.each { |error| puts "  - #{error}" }
      end

      unless warnings.empty?
        puts "⚠️  Warnings:"
        warnings.each { |warning| puts "  - #{warning}" }
      end
    end

    # Basic statistics
    if paths = spec["paths"]?
      path_count = paths.as_h.size
      puts "📊 Found #{path_count} API endpoints"
    end

    if components = spec["components"]?
      if schemas = components["schemas"]?
        schema_count = schemas.as_h.size
        puts "📋 Found #{schema_count} schema definitions"
      end
    end

    errors.empty?

  rescue ex
    puts "❌ Error parsing OpenAPI specification: #{ex.message}"
    false
  end
end

def generate_client_info(file_path : String)
  puts "\n🚀 Client Generation Commands:"
  puts "=" * 50

  languages = {
    "crystal" => "crystal",
    "javascript" => "javascript",
    "typescript" => "typescript-axios",
    "python" => "python",
    "go" => "go",
    "java" => "java",
    "csharp" => "csharp",
    "ruby" => "ruby",
    "php" => "php",
    "rust" => "rust"
  }

  languages.each do |lang, generator|
    puts "# #{lang.capitalize} Client"
    puts "openapi-generator generate -i #{file_path} -g #{generator} -o clients/#{lang}/"
    puts ""
  end

  puts "# View API Documentation"
  puts "docker run -p 8080:8080 -e SWAGGER_JSON=/docs/openapi.yaml -v $(pwd)/docs:/docs swaggerapi/swagger-ui"
  puts ""
  puts "# Validate with Swagger Editor"
  puts "https://editor.swagger.io/"
end

# Main execution
if ARGV.size != 1
  puts "Usage: crystal scripts/validate-openapi.cr <openapi-file>"
  exit 1
end

file_path = ARGV[0]

unless File.exists?(file_path)
  puts "❌ File not found: #{file_path}"
  exit 1
end

if validate_openapi_spec(file_path)
  generate_client_info(file_path)
  exit 0
else
  exit 1
end
