require "http/client"

class Fiber
  property joobq_traceparent : String?
end

module JoobQ::Delivery
  record TraceParent, trace_id : String, span_id : String do
    def self.parse(value : String?) : TraceParent?
      return unless value
      match = value.match(/\A00-([0-9a-f]{32})-([0-9a-f]{16})-[0-9a-f]{2}\z/) || raise ArgumentError.new("invalid traceparent")
      raise ArgumentError.new("zero trace identity") if match[1] == "0" * 32 || match[2] == "0" * 16
      new(match[1], match[2])
    end
  end

  class Span
    getter trace_id : String
    getter span_id : String = UUID.random.to_s.delete('-').byte_slice(0, 16)
    getter parent_id : String?
    getter queue : String
    getter operation : String
    getter job_id : String?
    getter started_ns : Int64 = Time.utc.to_unix_ms * 1_000_000
    property ended_ns : Int64 = 0_i64
    property failed : Bool = false

    def initialize(parent : String?, @queue, @operation, @job_id = nil)
      parsed = TraceParent.parse(parent)
      @trace_id = parsed.try(&.trace_id) || UUID.random.to_s.delete('-')
      @parent_id = parsed.try(&.span_id)
    end

    def traceparent : String
      "00-#{trace_id}-#{span_id}-01"
    end

    def finish(failed : Bool = false) : self
      @failed = failed
      @ended_ns = Time.utc.to_unix_ms * 1_000_000
      self
    end
  end

  module SpanExporter
    abstract def export(span : Span) : Nil
  end

  # OTLP/HTTP JSON exporter. It receives no job payload, exception message or
  # connection credentials. HTTP is opt-in for local collectors only.
  class OTLPExporter
    include SpanExporter

    def initialize(endpoint : String, @service_name : String = "joobq", allow_http : Bool = false)
      @uri = URI.parse(endpoint)
      unless @uri.scheme == "https" || (allow_http && @uri.scheme == "http")
        raise ArgumentError.new("OTLP requires HTTPS (or explicit local allow_http)")
      end
      raise ArgumentError.new("OTLP endpoint credentials are unsupported") if @uri.user || @uri.password
    end

    def export(span : Span) : Nil
      body = JSON.build do |json|
        json.object do
          json.field "resourceSpans" do
            json.array do
              json.object do
                json.field "resource" do
                  json.object do
                    json.field "attributes" do
                      json.array { attribute(json, "service.name", @service_name) }
                    end
                  end
                end
                json.field "scopeSpans" do
                  json.array do
                    json.object do
                      json.field "scope", {name: "joobq.delivery"}
                      json.field "spans" do
                        json.array do
                          json.object do
                            json.field "traceId", span.trace_id
                            json.field "spanId", span.span_id
                            json.field "parentSpanId", span.parent_id if span.parent_id
                            json.field "name", "#{span.operation} #{span.queue}"
                            json.field "kind", span.operation == "publish" ? 4 : 5
                            json.field "startTimeUnixNano", span.started_ns.to_s
                            json.field "endTimeUnixNano", span.ended_ns.to_s
                            json.field "status", {code: span.failed ? 2 : 1}
                            json.field "attributes" do
                              json.array do
                                attribute(json, "messaging.system", "joobq")
                                attribute(json, "messaging.destination.name", span.queue)
                                attribute(json, "messaging.operation.type", span.operation)
                                attribute(json, "messaging.message.id", span.job_id.not_nil!) if span.job_id
                              end
                            end
                          end
                        end
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end
      client = HTTP::Client.new(@uri)
      client.connect_timeout = 1.second
      client.read_timeout = 1.second
      client.write_timeout = 1.second
      response = client.post(@uri.request_target, HTTP::Headers{"Content-Type" => "application/json"}, body)
      raise "OTLP collector rejected export" unless 200 <= response.status_code < 300
    ensure
      client.try(&.close)
    end

    private def attribute(json : JSON::Builder, key : String, value : String) : Nil
      json.object do
        json.field "key", key
        json.field "value", {stringValue: value}
      end
    end
  end

  # Only the exporter fiber can block. Producers use a bounded nonblocking send,
  # and failures/drop counts are observable. No unlimited retries or buffers.
  class Telemetry
    getter dropped = Atomic(Int64).new(0_i64)
    getter failures = Atomic(Int64).new(0_i64)
    @publication_lock = Sync::Mutex.new
    @closed = Atomic(Bool).new(false)
    @done = Atomic(Bool).new(false)
    @sequence = Atomic(Int64).new(0_i64)

    def initialize(@exporter : SpanExporter, capacity : Int32 = 512, @sample_every : Int32 = 1)
      raise ArgumentError.new("telemetry capacity/sample interval must be positive") unless capacity > 0 && sample_every > 0
      @queue = Channel(Span).new(capacity)
      spawn(name: "delivery-telemetry") do
        loop do
          select
          when span = @queue.receive
            begin
              @exporter.export(span)
            rescue
              failures.add(1)
            end
          else
            break if @closed.get
            sleep 5.milliseconds
          end
        end
      ensure
        @done.set(true)
      end
    end

    def publish(span : Span) : Nil
      return unless @sequence.add(1) % @sample_every == 0
      @publication_lock.synchronize do
        if @closed.get
          dropped.add(1)
          return
        end
        select
        when @queue.send(span)
        else
          dropped.add(1)
        end
      end
    end

    def stop(wait : Time::Span) : Bool
      @publication_lock.synchronize { @closed.set(true) }
      deadline = Time.instant + wait
      until @done.get || Time.instant >= deadline
        sleep 5.milliseconds
      end
      @done.get
    end
  end
end
