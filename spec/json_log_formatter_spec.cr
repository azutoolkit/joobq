require "./spec_helper"

describe JoobQ::JSONLogFormatter do
  it "keeps structured identifiers and numeric timing in a single JSON record" do
    entry = Log::Entry.new("WORKER", Log::Severity::Info, "line one\nline two",
      Log::Metadata.build({job_id: "j1", worker_id: "w1", queue: "orders", execution_ms: 12.5}), nil)
    io = IO::Memory.new
    JoobQ::JSONLogFormatter.format(entry, io)
    io.to_s.lines.size.should eq(1)
    value = JSON.parse(io.to_s)
    value["data"]["job_id"].as_s.should eq("j1")
    value["data"]["execution_ms"].as_f.should eq(12.5)
    value["message"].as_s.should eq("line one\nline two")
  end
end
