module JoobQ
  # Internal routing/status operations without materializing arbitrary job payloads as JSON::Any trees.
  # The standard parser validates the whole document; numbers are copied without Float64 conversion.
  module SerializedJob
    def self.queue_name(raw : String) : String
      pull = JSON::PullParser.new(raw)
      destination = nil
      pull.read_object do |key|
        if key == "queue"
          destination = pull.kind.string? ? pull.read_string : pull.skip
        else
          pull.skip
        end
      end
      validate_end(pull)
      destination || raise ArgumentError.new("Job queue must be a string")
    end

    def self.for_enqueue(raw : String) : Tuple(String, String)
      pull = JSON::PullParser.new(raw)
      destination = nil
      payload = String.build(raw.bytesize + 32) do |io|
        JSON.build(io) do |json|
          json.object do
            pull.read_object do |key|
              case key
              when "status"
                pull.skip
              when "queue"
                # Like JSON.parse's object mapping, the last queue wins. Emit it once after validation.
                destination = pull.kind.string? ? pull.read_string : pull.skip
              else
                json.field(key) { pull.read_raw(json) }
              end
            end
            validate_end(pull)
            json.field("queue", destination || raise ArgumentError.new("Job queue must be a string"))
            json.field("status", "Enqueued")
          end
        end
      end
      queue = destination || raise ArgumentError.new("Job queue must be a string")
      {queue, payload}
    end

    private def self.validate_end(pull : JSON::PullParser) : Nil
      unless pull.kind.eof?
        raise JSON::ParseException.new("Unexpected data after job object", pull.line_number, pull.column_number)
      end
    end
  end
end
