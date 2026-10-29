require "log"
require "log/json"

module JoobQ
  # Opt-in NDJSON for Log::IOBackend. Structured job/worker/queue fields emitted
  # by the library live in `data`; application correlation fields live in `context`.
  # Applications must redact secrets before logging them, including exception messages.
  JSONLogFormatter = ::Log::Formatter.new do |entry, io|
    JSON.build(io) do |json|
      json.object do
        json.field "timestamp", entry.timestamp.to_rfc3339
        json.field "severity", entry.severity.to_s.downcase
        json.field "source", entry.source
        json.field "message", entry.message
        json.field "pid", Process.pid
        json.field "data", entry.data
        json.field "context", entry.context
        if error = entry.exception
          json.field "exception" do
            json.object do
              json.field "class", error.class.name
              json.field "message", error.message
            end
          end
        end
      end
    end
  end
end
