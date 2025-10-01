#!/usr/bin/env crystal

# Example Crystal client for JoobQ REST API
# This demonstrates how to use the generated OpenAPI client

require "http/client"
require "json"

module JoobQ
  class Client
    def initialize(@base_url : String = "http://localhost:8080")
    end

    # Enqueue a new job
    def enqueue_job(queue : String, job_type : String, data : Hash(String, JSON::Any),
                    priority : Int32 = 0, retries : Int32 = 3, delay : Int32 = 0)
      payload = {
        queue:    queue,
        job_type: job_type,
        data:     data,
        priority: priority,
        retries:  retries,
        delay:    delay,
      }

      response = HTTP::Client.post("#{@base_url}/joobq/jobs") do |request|
        request.headers["Content-Type"] = "application/json"
        request.body = payload.to_json
      end

      case response.status_code
      when 201
        JSON.parse(response.body).as_h
      when 400, 404, 500
        raise "API Error: #{response.body}"
      else
        raise "Unexpected response: #{response.status_code}"
      end
    end

    # Get job registry
    def get_job_registry
      response = HTTP::Client.get("#{@base_url}/joobq/jobs/registry")

      case response.status_code
      when 200
        JSON.parse(response.body)
      else
        raise "API Error: #{response.body}"
      end
    end

    # Health check
    def health_check
      response = HTTP::Client.get("#{@base_url}/joobq/health/check")

      case response.status_code
      when 200
        JSON.parse(response.body).as_h
      else
        raise "API Error: #{response.body}"
      end
    end

    # Reprocess busy jobs
    def reprocess_busy_jobs(queue_name : String)
      response = HTTP::Client.post("#{@base_url}/joobq/queues/#{queue_name}/reprocess")

      case response.status_code
      when 200
        JSON.parse(response.body).as_h
      when 400, 404, 500
        raise "API Error: #{response.body}"
      else
        raise "Unexpected response: #{response.status_code}"
      end
    end

    # Get error statistics
    def get_error_stats
      response = HTTP::Client.get("#{@base_url}/joobq/errors/stats")

      case response.status_code
      when 200
        JSON.parse(response.body).as_h
      else
        raise "API Error: #{response.body}"
      end
    end

    # Get recent errors
    def get_recent_errors(limit : Int32 = 20)
      response = HTTP::Client.get("#{@base_url}/joobq/errors/recent?limit=#{limit}")

      case response.status_code
      when 200
        JSON.parse(response.body).as_a
      else
        raise "API Error: #{response.body}"
      end
    end

    # Get errors by type
    def get_errors_by_type(error_type : String, limit : Int32 = 20)
      response = HTTP::Client.get("#{@base_url}/joobq/errors/by-type?type=#{error_type}&limit=#{limit}")

      case response.status_code
      when 200
        JSON.parse(response.body).as_a
      when 400
        raise "API Error: #{response.body}"
      else
        raise "Unexpected response: #{response.status_code}"
      end
    end

    # Get errors by queue
    def get_errors_by_queue(queue_name : String, limit : Int32 = 20)
      response = HTTP::Client.get("#{@base_url}/joobq/errors/by-queue?queue=#{queue_name}&limit=#{limit}")

      case response.status_code
      when 200
        JSON.parse(response.body).as_a
      when 400
        raise "API Error: #{response.body}"
      else
        raise "Unexpected response: #{response.status_code}"
      end
    end
  end
end

# Example usage
if PROGRAM_NAME.includes?("crystal_client_example.cr")
  puts "🚀 JoobQ Crystal Client Example"
  puts "=" * 40

  client = JoobQ::Client.new

  begin
    # Health check
    puts "📊 Checking system health..."
    health = client.health_check
    puts "✅ System status: #{health["status"]}"

    # Enqueue a job
    puts "\n📤 Enqueuing a job..."
    job_data = {
      "email"    => "user@example.com",
      "subject"  => "Welcome to JoobQ",
      "template" => "welcome",
    }

    response = client.enqueue_job(
      queue: "email",
      job_type: "EmailJob",
      data: job_data,
      priority: 5,
      retries: 3
    )

    puts "✅ Job enqueued: #{response["job_id"]}"

    # Get error statistics
    puts "\n📈 Getting error statistics..."
    stats = client.get_error_stats
    puts "📊 Error counts: #{stats["error_counts"]}"
    puts "📊 Recent errors: #{stats["recent_errors_count"]}"

    # Get job registry
    puts "\n📋 Getting job registry..."
    registry = client.get_job_registry
    puts "📋 Registry: #{registry}"

    # Reprocess busy jobs
    puts "\n🔄 Reprocessing busy jobs..."
    reprocess_result = client.reprocess_busy_jobs("email")
    puts "🔄 Result: #{reprocess_result["status"]} - #{reprocess_result["message"]}"
  rescue ex
    puts "❌ Error: #{ex.message}"
  end
end
