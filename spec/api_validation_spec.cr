require "./spec_helper"
require "json"

module JoobQ
  describe APIValidation do
    describe ".validate_job_enqueue" do
      it "validates valid job payload" do
        payload = JSON.parse({
          queue:    "example",
          job_type: "ExampleJob",
          data:     {x: 1},
        }.to_json)

        result = APIValidation.validate_job_enqueue(payload)
        result.success?.should be_true
      end

      it "rejects empty queue name" do
        payload = JSON.parse({
          queue:    "",
          job_type: "ExampleJob",
          data:     {x: 1},
        }.to_json)

        result = APIValidation.validate_job_enqueue(payload)
        result.success?.should be_false
        result.errors.any? { |e| e.field == "queue" }.should be_true
      end

      it "rejects missing queue" do
        payload = JSON.parse({
          job_type: "ExampleJob",
          data:     {x: 1},
        }.to_json)

        result = APIValidation.validate_job_enqueue(payload)
        result.success?.should be_false
      end

      it "rejects non-existent queue" do
        payload = JSON.parse({
          queue:    "nonexistent",
          job_type: "ExampleJob",
          data:     {x: 1},
        }.to_json)

        result = APIValidation.validate_job_enqueue(payload)
        result.success?.should be_false
        result.errors.any? { |e| e.code == "queue_not_found" }.should be_true
      end

      it "rejects invalid job type" do
        payload = JSON.parse({
          queue:    "example",
          job_type: "invalid-type",
          data:     {x: 1},
        }.to_json)

        result = APIValidation.validate_job_enqueue(payload)
        result.success?.should be_false
      end

      it "rejects invalid data type" do
        payload = JSON.parse({
          queue:    "example",
          job_type: "ExampleJob",
          data:     "not an object",
        }.to_json)

        result = APIValidation.validate_job_enqueue(payload)
        result.success?.should be_false
      end

      it "validates priority range" do
        payload = JSON.parse({
          queue:    "example",
          job_type: "ExampleJob",
          data:     {x: 1},
          priority: 150,
        }.to_json)

        result = APIValidation.validate_job_enqueue(payload)
        result.success?.should be_false
        result.errors.any? { |e| e.field == "priority" }.should be_true
      end

      it "validates delay range" do
        payload = JSON.parse({
          queue:    "example",
          job_type: "ExampleJob",
          data:     {x: 1},
          delay:    -10,
        }.to_json)

        result = APIValidation.validate_job_enqueue(payload)
        result.success?.should be_false
      end

      it "validates retries range" do
        payload = JSON.parse({
          queue:    "example",
          job_type: "ExampleJob",
          data:     {x: 1},
          retries:  20,
        }.to_json)

        result = APIValidation.validate_job_enqueue(payload)
        result.success?.should be_false
      end
    end

    describe ".validate_json_request" do
      it "accepts valid JSON" do
        body = {test: "value"}.to_json
        result = APIValidation.validate_json_request(body)
        result.success?.should be_true
        result.data.should_not be_nil
      end

      it "rejects invalid JSON" do
        body = "{invalid json"
        result = APIValidation.validate_json_request(body)
        result.success?.should be_false
      end

      it "rejects empty body" do
        result = APIValidation.validate_json_request("")
        result.success?.should be_false
      end

      it "rejects nil body" do
        result = APIValidation.validate_json_request(nil)
        result.success?.should be_false
      end
    end

    describe ".validate_content_type" do
      it "accepts application/json" do
        result = APIValidation.validate_content_type("application/json")
        result.success?.should be_true
      end

      it "accepts application/json with charset" do
        result = APIValidation.validate_content_type("application/json; charset=utf-8")
        result.success?.should be_true
      end

      it "rejects text/plain" do
        result = APIValidation.validate_content_type("text/plain")
        result.success?.should be_false
      end

      it "rejects missing content type" do
        result = APIValidation.validate_content_type(nil)
        result.success?.should be_false
      end
    end

    describe ".validate_error_type" do
      it "accepts valid error types" do
        valid_types = [
          "validation_error",
          "connection_error",
          "timeout_error",
          "serialization_error",
          "configuration_error",
          "implementation_error",
          "unknown_error",
        ]

        valid_types.each do |error_type|
          result = APIValidation.validate_error_type(error_type)
          result.success?.should be_true
        end
      end

      it "rejects invalid error type" do
        result = APIValidation.validate_error_type("invalid_type")
        result.success?.should be_false
      end
    end

    describe ".validate_queue_name" do
      it "accepts valid queue name" do
        result = APIValidation.validate_queue_name("example")
        result.success?.should be_true
      end

      it "rejects empty queue name" do
        result = APIValidation.validate_queue_name("")
        result.success?.should be_false
      end

      it "rejects invalid characters" do
        result = APIValidation.validate_queue_name("test@queue")
        result.success?.should be_false
      end

      it "rejects non-existent queue" do
        result = APIValidation.validate_queue_name("nonexistent")
        result.success?.should be_false
      end
    end

    describe ".sanitize_string" do
      it "escapes HTML entities" do
        input = "<script>alert('xss')</script>"
        output = APIValidation.sanitize_string(input)
        output.should_not contain("<script>")
        output.should contain("&lt;script&gt;")
      end

      it "escapes quotes" do
        input = "test\"value"
        output = APIValidation.sanitize_string(input)
        output.should contain("&quot;")
      end

      it "escapes ampersands" do
        input = "test&value"
        output = APIValidation.sanitize_string(input)
        output.should contain("&amp;")
      end
    end

    describe ".sanitize_job_data" do
      it "sanitizes string values" do
        data = JSON.parse({test: "<script>"}.to_json)
        result = APIValidation.sanitize_job_data(data)
        result["test"].as_s.should contain("&lt;")
      end

      it "recursively sanitizes nested objects" do
        data = JSON.parse({
          outer: {
            inner: "<script>",
          },
        }.to_json)

        result = APIValidation.sanitize_job_data(data)
        result["outer"]["inner"].as_s.should contain("&lt;")
      end

      it "sanitizes array values" do
        data = JSON.parse({
          items: ["<script>", "safe"],
        }.to_json)

        result = APIValidation.sanitize_job_data(data)
        result["items"].as_a[0].as_s.should contain("&lt;")
      end

      it "preserves numeric values" do
        data = JSON.parse({count: 42}.to_json)
        result = APIValidation.sanitize_job_data(data)
        result["count"].as_i.should eq(42)
      end
    end

    describe "error response format" do
      it "generates proper error response" do
        result = APIValidation::ValidationResult.new(false)
        result.add_error("field1", "Error message")

        response = result.error_response
        response["error"].as_s.should eq("Validation failed")
        response["validation_errors"].as_a.size.should eq(1)
        response["timestamp"].should_not be_nil
      end
    end
  end
end
