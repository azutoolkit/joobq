require "json"

module JoobQ
  # Comprehensive API validation system for JoobQ REST API
  class APIValidation
    # Validation error details
    class ValidationError
      include JSON::Serializable

      getter field : String
      getter message : String
      getter value : JSON::Any?
      getter code : String

      def initialize(@field : String, @message : String, @value : JSON::Any? = nil, @code : String = "validation_error")
      end
    end

    # Validation result container
    class ValidationResult
      include JSON::Serializable

      getter valid : Bool
      getter errors : Array(ValidationError)
      getter data : JSON::Any?

      def initialize(@valid : Bool, @errors : Array(ValidationError) = [] of ValidationError, @data : JSON::Any? = nil)
      end

      def data=(value : JSON::Any?)
        @data = value
      end

      def add_error(field : String, message : String, value : JSON::Any? = nil, code : String = "validation_error")
        @errors << ValidationError.new(field, message, value, code)
        @valid = false
      end

      def success?
        @valid && @errors.empty?
      end

      def error_response : Hash(String, JSON::Any)
        {
          "error"             => JSON::Any.new("Validation failed"),
          "message"           => JSON::Any.new("One or more validation errors occurred"),
          "validation_errors" => JSON::Any.new(@errors.map { |error| JSON.parse(error.to_json) }),
          "timestamp"         => JSON::Any.new(Time.local.to_rfc3339),
        }
      end
    end

    # Job enqueue validation
    def self.validate_job_enqueue(payload : JSON::Any) : ValidationResult
      result = ValidationResult.new(true)

      # Required fields validation
      if payload["queue"]?
        queue_name = payload["queue"].to_s
        if queue_name.empty?
          result.add_error("queue", "Queue name cannot be empty")
        elsif !valid_queue_name?(queue_name)
          result.add_error("queue", "Queue name contains invalid characters", JSON::Any.new(queue_name), "invalid_format")
        elsif !queue_exists?(queue_name)
          result.add_error("queue", "Queue '#{queue_name}' does not exist", JSON::Any.new(queue_name), "queue_not_found")
        end
      else
        result.add_error("queue", "Queue name is required")
      end

      if payload["job_type"]?
        job_type = payload["job_type"].to_s
        if job_type.empty?
          result.add_error("job_type", "Job type cannot be empty")
        elsif !valid_job_type?(job_type)
          result.add_error("job_type", "Job type contains invalid characters", JSON::Any.new(job_type), "invalid_format")
        end
      else
        result.add_error("job_type", "Job type is required")
      end

      if payload["data"]?
        unless payload["data"].as_h?
          result.add_error("data", "Job data must be an object")
        end
      else
        result.add_error("data", "Job data is required")
      end

      # Optional fields validation
      if payload["priority"]?
        priority = payload["priority"]
        if priority.as_i?
          priority_val = priority.as_i
          if priority_val < 0 || priority_val > 100
            result.add_error("priority", "Priority must be between 0 and 100", priority, "out_of_range")
          end
        else
          result.add_error("priority", "Priority must be an integer", priority, "invalid_type")
        end
      end

      if payload["delay"]?
        delay = payload["delay"]
        if delay.as_i?
          delay_val = delay.as_i
          if delay_val < 0
            result.add_error("delay", "Delay must be non-negative", delay, "out_of_range")
          elsif delay_val > 86400 # 24 hours
            result.add_error("delay", "Delay cannot exceed 24 hours (86400 seconds)", delay, "out_of_range")
          end
        else
          result.add_error("delay", "Delay must be an integer", delay, "invalid_type")
        end
      end

      if payload["retries"]?
        retries = payload["retries"]
        if retries.as_i?
          retries_val = retries.as_i
          if retries_val < 0 || retries_val > 10
            result.add_error("retries", "Retries must be between 0 and 10", retries, "out_of_range")
          end
        else
          result.add_error("retries", "Retries must be an integer", retries, "invalid_type")
        end
      end

      result
    end

    # Query parameter validation for error endpoints
    def self.validate_error_query_params(params : HTTP::Params) : ValidationResult
      result = ValidationResult.new(true)

      # Validate limit parameter
      if limit_param = params["limit"]?
        begin
          limit = limit_param.to_i
          if limit < 1 || limit > 100
            result.add_error("limit", "Limit must be between 1 and 100", JSON::Any.new(limit), "out_of_range")
          end
        rescue
          result.add_error("limit", "Limit must be a valid integer", JSON::Any.new(limit_param), "invalid_type")
        end
      end

      result
    end

    # Validate error type parameter
    def self.validate_error_type(error_type : String) : ValidationResult
      result = ValidationResult.new(true)

      valid_types = [
        "validation_error",
        "connection_error",
        "timeout_error",
        "serialization_error",
        "configuration_error",
        "implementation_error",
        "unknown_error",
      ]

      unless valid_types.includes?(error_type)
        result.add_error("type", "Invalid error type. Must be one of: #{valid_types.join(", ")}",
          JSON::Any.new(error_type), "invalid_enum")
      end

      result
    end

    # Validate queue name parameter
    def self.validate_queue_name(queue_name : String) : ValidationResult
      result = ValidationResult.new(true)

      if queue_name.empty?
        result.add_error("queue_name", "Queue name cannot be empty")
      elsif !valid_queue_name?(queue_name)
        result.add_error("queue_name", "Queue name contains invalid characters",
          JSON::Any.new(queue_name), "invalid_format")
      elsif !queue_exists?(queue_name)
        result.add_error("queue_name", "Queue '#{queue_name}' does not exist",
          JSON::Any.new(queue_name), "queue_not_found")
      end

      result
    end

    # Validate JSON request body
    def self.validate_json_request(body : String?) : ValidationResult
      result = ValidationResult.new(true)

      unless body
        result.add_error("body", "Request body is required")
        return result
      end

      if body.empty?
        result.add_error("body", "Request body cannot be empty")
        return result
      end

      begin
        parsed = JSON.parse(body)
        result.data = parsed
      rescue ex : JSON::Error
        result.add_error("body", "Invalid JSON format: #{ex.message}",
          JSON::Any.new(body), "invalid_json")
      rescue ex
        result.add_error("body", "Failed to parse request body: #{ex.message}",
          JSON::Any.new(body), "parse_error")
      end

      result
    end

    # Validate content type
    def self.validate_content_type(content_type : String?) : ValidationResult
      result = ValidationResult.new(true)

      unless content_type
        result.add_error("content_type", "Content-Type header is required")
        return result
      end

      unless content_type.includes?("application/json")
        result.add_error("content_type", "Content-Type must be 'application/json'",
          JSON::Any.new(content_type), "invalid_content_type")
      end

      result
    end

    # Helper methods
    private def self.valid_queue_name?(name : String) : Bool
      # Queue names should be alphanumeric with underscores and hyphens
      /^[a-zA-Z0-9_-]+$/.matches?(name) && name.size <= 50
    end

    private def self.valid_job_type?(job_type : String) : Bool
      # Job types should be valid class names
      /^[A-Z][a-zA-Z0-9_]*$/.matches?(job_type) && job_type.size <= 100
    end

    private def self.valid_job_id?(job_id : String) : Bool
      # Job IDs should be UUIDs or alphanumeric with hyphens/underscores
      /^[a-zA-Z0-9_-]+$/.matches?(job_id) && job_id.size <= 100
    end

    # Validate job ID from URL path
    def self.validate_job_id(job_id : String) : ValidationResult
      result = ValidationResult.new(true)

      if job_id.empty?
        result.add_error("job_id", "Job ID cannot be empty")
      elsif !valid_job_id?(job_id)
        result.add_error("job_id", "Job ID contains invalid characters",
          JSON::Any.new(job_id), "invalid_format")
      end

      result
    end

    # Sanitize error message for external clients (hide internal details)
    def self.safe_error_message(operation : String) : String
      "An error occurred while #{operation}. Please try again later."
    end

    private def self.queue_exists?(name : String) : Bool
      JoobQ.queues.has_key?(name)
    end

    # Sanitize input to prevent injection attacks
    def self.sanitize_string(input : String) : String
      input.gsub('&', "&amp;")
        .gsub('<', "&lt;")
        .gsub('>', "&gt;")
        .gsub('"', "&quot;")
        .gsub("'", "&#x27;")
    end

    # Validate and sanitize job data
    def self.sanitize_job_data(data : JSON::Any) : JSON::Any
      case data
      when JSON::Any
        if data.as_s?
          sanitized = sanitize_string(data.as_s)
          JSON::Any.new(sanitized)
        elsif data.as_h?
          sanitized_hash = {} of String => JSON::Any
          data.as_h.each do |key, value|
            sanitized_key = sanitize_string(key)
            sanitized_value = sanitize_job_data(value)
            sanitized_hash[sanitized_key] = sanitized_value
          end
          JSON::Any.new(sanitized_hash)
        elsif data.as_a?
          sanitized_array = data.as_a.map { |item| sanitize_job_data(item) }
          JSON::Any.new(sanitized_array)
        else
          data
        end
      else
        data
      end
    end
  end
end
