require "./spec_helper"

private SRC = File.expand_path("../src", __DIR__)

# Every coded exception class (as a constructor: `.new(message)`), its code and its area (the code's hundreds digit).
private macro coded(*entries)
  [
    {% for entry in entries %}
      { ->(message : String?) { {{ entry[0] }}.new(message).as(Exception) }, {{ entry[1] }}, {{ entry[2] }} },
    {% end %}
  ]
end

private CODED = coded(
  {JoobQ::ConfigNotInitializedError, "JQ-101", 1},
  {JoobQ::ConfigFileNotFoundError, "JQ-102", 1},
  {JoobQ::ConfigParseError, "JQ-103", 1},
  {JoobQ::ConfigValidationError, "JQ-104", 1},
  {JoobQ::ConfigLoadError, "JQ-105", 1},
  {JoobQ::QueueFactoryError, "JQ-301", 3},
  {JoobQ::NonRetryableError, "JQ-302", 3},
  {JoobQ::Encryption::Error, "JQ-401", 4},
  {JoobQ::Encryption::ConfigurationError, "JQ-402", 4},
)

private def code_of(error : Exception) : JoobQ::ErrorCode
  error.as(JoobQ::Coded).joobq_error_code
end

private def suffix(code : String) : String
  " [#{code}] https://joobq.io/errors/#{code}"
end

private def ends_once(message : String?, code : String) : Nil
  message = message.to_s
  message.should end_with(suffix(code))
  message.scan("[#{code}]").size.should eq(1)
  message.scan("https://joobq.io/errors/#{code}").size.should eq(1)
end

# `joobq_error_code "JQ-n"` declarations and `ErrorCodes["JQ-n"]` raise sites in src, outside the catalog itself.
private def codes_used_in_src : Set(String)
  used = Set(String).new
  Dir.glob("#{SRC}/**/*.cr").each do |path|
    next if path.ends_with?("/error_codes.cr")
    text = File.read(path)
    text.scan(/joobq_error_code "(JQ-\d+)"/) { |m| used << m[1] }
    text.scan(/ErrorCodes\["(JQ-\d+)"\]/) { |m| used << m[1] }
  end
  used
end

describe JoobQ::ErrorCodes do
  it "has well-formed, unique codes with a resolution URL" do
    codes = JoobQ::ErrorCodes.all.map(&.code)
    codes.should_not be_empty
    codes.uniq.size.should eq(codes.size)
    JoobQ::ErrorCodes.all.each do |entry|
      entry.code.should match(/\AJQ-[1-5]\d\d\z/)
      entry.url.should eq("https://joobq.io/errors/#{entry.code}")
      entry.title.should_not be_empty
      entry.summary.should_not be_empty
      entry.fix.should_not be_empty
      JoobQ::ErrorCodes[entry.code].should eq(entry)
    end
  end

  it "raises KeyError for an unknown code" do
    expect_raises(KeyError) { JoobQ::ErrorCodes["JQ-999"] }
    JoobQ::ErrorCodes["JQ-999"]?.should be_nil
  end

  it "serializes the catalog ordered by code, and the JSON round-trips" do
    json = JoobQ::ErrorCodes.to_json
    parsed = Array(JoobQ::ErrorCode).from_json(json)
    parsed.should eq(JoobQ::ErrorCodes.all)
    parsed.map(&.code).should eq(parsed.map(&.code).sort)
    JSON.parse(json).as_a.first.as_h.keys.should eq(%w[code title summary fix url])
  end

  it "cannot drift from src: every code used exists, every code is used" do
    used = codes_used_in_src
    catalog = JoobQ::ErrorCodes.all.map(&.code).to_set
    (used - catalog).should be_empty
    (catalog - used).should be_empty
  end

  it "has a class per coded exception in the code's own area" do
    CODED.each do |build, code, area|
      error = build.call("boom")
      code_of(error).code.should eq(code)
      code_of(error).should eq(JoobQ::ErrorCodes[code])
      code[3].to_i.should eq(area)
    end
  end
end

describe JoobQ::Coded do
  it "ends every coded message with its code and URL exactly once" do
    CODED.each do |build, code, _|
      ends_once(build.call("boom").message, code)
      build.call("boom").message.should eq("boom#{suffix(code)}")
    end
  end

  it "puts the title before the suffix when the message is nil" do
    CODED.each do |build, code, _|
      build.call(nil).message.should eq("#{JoobQ::ErrorCodes[code].title}#{suffix(code)}")
    end
  end

  it "does not repeat the suffix when a coded message is rebuilt or re-raised" do
    CODED.each do |build, code, _|
      first = build.call("boom")
      rebuilt = build.call("#{first.message} in config/joobq.yml")
      rebuilt.message.should eq("boom in config/joobq.yml#{suffix(code)}")
      ends_once(build.call(rebuilt.message).message, code)

      caught = begin
        begin
          raise first
        rescue ex
          raise ex
        end
      rescue ex
        ex
      end
      ends_once(caught.message, code)
      caught.to_s.should eq(caught.message)
    end
  end

  it "is inherited by a subclass that declares no code" do
    error = JoobQ::Encryption::PlaintextRefused.new("refused")
    error.joobq_error_code.code.should eq("JQ-401")
    ends_once(error.message, "JQ-401")
  end

  it "keeps a user subclass of NonRetryableError coded" do
    error = ErrorCodesSpec::Declined.new("card declined")
    ends_once(error.message, "JQ-302")
    error.message.to_s.should start_with("card declined")
  end

  it "leaves `error_code` to a user subclass that defines its own" do
    error = ErrorCodesSpec::WithOwnCode.new("card declined", "card_declined")
    error.error_code.should eq("card_declined")
    error.joobq_error_code.code.should eq("JQ-302")
    error.message.should eq("card declined#{suffix("JQ-302")}")
    ends_once(error.message, "JQ-302")
  end
end

module ErrorCodesSpec
  class Declined < JoobQ::NonRetryableError
  end

  # A user's error with a field of its own named `error_code`: it must compile and keep its value.
  class WithOwnCode < JoobQ::NonRetryableError
    getter error_code : String

    def initialize(message : String, @error_code : String)
      super(message)
    end
  end
end

describe "error codes on real errors" do
  it "JQ-1xx: loading a missing configuration file" do
    error = expect_raises(JoobQ::ConfigLoadError, "Configuration file not found") do
      JoobQ::YamlConfigLoader.load_from_file("/nonexistent/joobq-#{UUID.random}.yml")
    end
    ends_once(error.message, "JQ-105")
    error.message.to_s.should contain("[JQ-102]")
  end

  it "JQ-1xx: invalid YAML and a failed schema check" do
    parse = expect_raises(JoobQ::ConfigParseError) { JoobQ::YamlConfigLoader.load_from_string("joobq: [", "x.yml") }
    ends_once(parse.message, "JQ-103")

    invalid = expect_raises(JoobQ::ConfigLoadError, /Missing 'joobq' root key in x\.yml/) do
      JoobQ::YamlConfigLoader.load_from_string("other: 1", "x.yml")
    end
    ends_once(invalid.message, "JQ-105")
    invalid.message.to_s.should contain("Missing 'joobq' root key in x.yml#{suffix("JQ-104")}")
  end

  it "JQ-104: an out-of-range setting" do
    config = JoobQ::Configure.new
    config.retries = -1
    error = expect_raises(JoobQ::ConfigValidationError, /retries must be greater than or equal to 0/) do
      config.validate_configuration
    end
    ends_once(error.message, "JQ-104")
  end

  it "JQ-2xx: a durable runtime on Redis that is not durable" do
    redis = JoobQ::RedisStore.instance.redis
    original = redis.command(["CONFIG", "GET", "maxmemory-policy"]).as(Array)[1].as(String)
    begin
      redis.command(["CONFIG", "SET", "maxmemory-policy", "allkeys-lru"])
      error = expect_raises(ArgumentError, /durable runtime requires appendonly=yes/) do
        JoobQ::Delivery::Runtime.new(JoobQ::RedisStore.instance, "codes-#{UUID.random}")
      end
      ends_once(error.message, "JQ-201")
    ensure
      redis.command(["CONFIG", "SET", "maxmemory-policy", original])
    end
  end

  it "JQ-3xx: creating a queue for an unregistered job class" do
    error = expect_raises(JoobQ::QueueFactoryError, /not registered/) do
      JoobQ::QueueFactory.create_queue("codes", "NoSuchJob", 1)
    end
    ends_once(error.message, "JQ-301")
  end

  it "JQ-4xx: malformed payload keys" do
    error = expect_raises(JoobQ::Encryption::ConfigurationError, /no key given/) do
      JoobQ::Encryption::Keys.parse([] of String)
    end
    ends_once(error.message, "JQ-402")
  end
end
