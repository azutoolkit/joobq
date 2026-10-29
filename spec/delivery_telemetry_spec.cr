require "./spec_helper"

class RecordingSpanExporter
  include JoobQ::Delivery::SpanExporter
  getter spans = Channel(JoobQ::Delivery::Span).new(100)

  def export(span : JoobQ::Delivery::Span) : Nil
    spans.send(span)
  end
end

class BlockedSpanExporter
  include JoobQ::Delivery::SpanExporter
  getter release = Channel(Nil).new(10)

  def export(span : JoobQ::Delivery::Span) : Nil
    release.receive
    raise "collector offline"
  end
end

describe "delivery telemetry" do
  it "links producer and consumer spans without payload data" do
    exporter = RecordingSpanExporter.new
    telemetry = JoobQ::Delivery::Telemetry.new(exporter)
    runtime = JoobQ::Delivery::Runtime.new(JoobQ::RedisStore.instance, "trace-#{UUID.random}", telemetry: telemetry)
    ledger = runtime.register("work") { |raw, context| JoobQ::Delivery::Outcome.new }
    runtime.admit("work", "request", "secret-never-export")
    runtime.start
    eventually { ledger.resolve("request").try(&.state.completed?) }.should be_true
    runtime.stop(2.seconds).clean.should be_true
    spans = [exporter.spans.receive, exporter.spans.receive]
    producer = spans.find { |span| span.operation == "publish" }.not_nil!
    consumer = spans.find { |span| span.operation == "process" }.not_nil!
    consumer.trace_id.should eq(producer.trace_id)
    consumer.parent_id.should eq(producer.span_id)
    runtime.prometheus.should contain("joobq_delivery_telemetry_dropped_total 0")
  ensure
    runtime.try(&.stop(1.second))
  end

  it "drops excess telemetry without blocking job-side publication" do
    exporter = BlockedSpanExporter.new
    telemetry = JoobQ::Delivery::Telemetry.new(exporter, capacity: 2)
    started = Time.instant
    100.times { telemetry.publish(JoobQ::Delivery::Span.new(nil, "work", "process").finish) }
    (Time.instant - started).should be < 500.milliseconds
    telemetry.dropped.get.should be >= 97
    telemetry.stop(10.milliseconds).should be_false
    4.times { exporter.release.send(nil) }
    eventually { telemetry.stop(10.milliseconds) }.should be_true
    telemetry.failures.get.should be > 0
  end

  it "sends valid OTLP HTTP JSON to an explicitly configured local collector" do
    received = Channel(String).new(1)
    server = HTTP::Server.new do |context|
      received.send(context.request.body.not_nil!.gets_to_end)
      context.response.status_code = 200
      context.response.print("{}")
    end
    address = server.bind_tcp("127.0.0.1", 0)
    spawn { server.listen }
    exporter = JoobQ::Delivery::OTLPExporter.new("http://127.0.0.1:#{address.port}/v1/traces", allow_http: true)
    exporter.export(JoobQ::Delivery::Span.new(nil, "work", "process", "id").finish)
    document = JSON.parse(received.receive)
    document["resourceSpans"][0]["scopeSpans"][0]["spans"][0]["kind"].as_i.should eq(5)
    expect_raises(ArgumentError) { JoobQ::Delivery::OTLPExporter.new("http://localhost:4318/v1/traces") }
  ensure
    server.try(&.close)
  end
end
