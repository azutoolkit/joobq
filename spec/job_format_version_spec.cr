require "./spec_helper"

# The stored job carries the version of its format, `v`. A reader of an older format version is not meant to guess at a
# newer one: it refuses it by name. A job without `v` was written by 0.6 and is read as it always was.
describe "the job format version" do
  it "is written into every stored job" do
    JSON.parse(ExampleJob.new(1).to_json)["v"].as_i.should eq(JoobQ::Job::FORMAT_VERSION)
    JoobQ::Job::FORMAT_VERSION.should eq(1)
  end

  it "reads its own version" do
    ExampleJob.from_json(ExampleJob.new(7).to_json).x.should eq(7)
  end

  it "refuses an unknown future version, naming it" do
    future = JSON.parse(ExampleJob.new(1).to_json).as_h.merge({"v" => JSON::Any.new(2_i64)}).to_json
    error = expect_raises(JoobQ::UnsupportedJobVersion) { ExampleJob.from_json(future) }
    error.message.to_s.should contain("format version 2")
    error.message.to_s.should contain("upgrade")
    error.should be_a(JSON::ParseException)
  end

  it "reads a 0.6 job that has no version, and writes it back with one" do
    old = JSON.parse(ExampleJob.new(3).to_json).as_h.reject("v").to_json
    old.should_not contain("\"v\"")
    job = ExampleJob.from_json(old)
    job.x.should eq(3)
    JSON.parse(job.to_json)["v"].as_i.should eq(1)
  end

  it "survives a round trip through the serialized-job reader used by the scheduler and the promotion" do
    _, payload = JoobQ::SerializedJob.for_enqueue(ExampleJob.new(1).to_json)
    JSON.parse(payload)["v"].as_i.should eq(1)
  end
end
