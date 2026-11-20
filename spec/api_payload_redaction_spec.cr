require "./spec_helper"

class PaymentJob
  include JoobQ::Job

  @queue = "payments"
  @retries = 0

  property order_id : Int32 = 0
  property password : String = ""
  property api_key : String = ""
  property card : Hash(String, String) = {} of String => String
  property recipients : Array(Hash(String, String)) = [] of Hash(String, String)
  encrypted_property sealed_note : String = ""

  def initialize
  end

  def perform
  end
end

module JoobQ
  describe "payload exposure through the management API" do
    get = ->(path : String) do
      io = IO::Memory.new
      context = HTTP::Server::Context.new(HTTP::Request.new("GET", path), HTTP::Server::Response.new(io))
      handler = APIHandler.new(unsafe_no_auth: true)
      handler.next = ->(_ctx : HTTP::Server::Context) { }
      handler.call(context)
      context.response.close
      io.rewind
      parsed = HTTP::Client::Response.from_io(io)
      {parsed.status_code, parsed.body}
    end

    plain_password = "hunter2-correct-horse"
    plain_key = "sk_live_0123456789abcdef"
    nested_token = "tok_nested_123456"
    sealed_plain = "the-sealed-note-in-clear"

    build_job = -> do
      job = PaymentJob.new
      job.order_id = 4242
      job.password = plain_password
      job.api_key = plain_key
      job.card = {"number" => "4111111111111111", "Auth-Token" => nested_token, "brand" => "visa"}
      job.recipients = [{"email" => "a@example.com", "secret" => "nested-in-array-secret"}]
      job.sealed_note = sealed_plain
      job
    end

    before_each do
      JoobQ.reset
      JoobQ.config.payload_encryption("k1:" + "11" * 32)
      JoobQ.config.redact_api_payloads = true
      JoobQ.config.redacted_payload_keys = PayloadRedaction::DEFAULT_KEYS.dup
      JoobQ.error_monitor.reset
    end

    after_each do
      JoobQ.config.redact_api_payloads = true
      JoobQ.config.redacted_payload_keys = PayloadRedaction::DEFAULT_KEYS.dup
    end

    refute_secrets = ->(body : String) do
      {"hunter2-correct-horse", "sk_live_0123456789abcdef", "tok_nested_123456", "nested-in-array-secret", "the-sealed-note-in-clear"}.each do |secret|
        body.should_not contain(secret)
      end
    end

    it "hides arguments whose name matches the secret list from GET /joobq/jobs/dead" do
      job = build_job.call
      job.dead!
      JoobQ.store.as(RedisStore).redis.zadd(Keys::DEAD_LETTER, 1_i64, job.to_json)

      status, body = get.call("/joobq/jobs/dead")

      status.should eq(200)
      refute_secrets.call(body)
      listed = JSON.parse(body)["jobs"].as_a.first
      listed["password"].as_s.should eq(PayloadRedaction::REDACTED)
      listed["api_key"].as_s.should eq(PayloadRedaction::REDACTED)
      listed["card"]["Auth-Token"].as_s.should eq(PayloadRedaction::REDACTED)
      listed["recipients"][0]["secret"].as_s.should eq(PayloadRedaction::REDACTED)
    end

    it "keeps every other argument and the job's bookkeeping readable" do
      job = build_job.call
      job.dead!
      JoobQ.store.as(RedisStore).redis.zadd(Keys::DEAD_LETTER, 1_i64, job.to_json)

      listed = JSON.parse(get.call("/joobq/jobs/dead")[1])["jobs"].as_a.first

      listed["order_id"].as_i.should eq(4242)
      listed["jid"].as_s.should eq(job.jid.to_s)
      listed["queue"].as_s.should eq("payments")
      listed["status"].as_s.should eq("dead")
      listed["card"]["brand"].as_s.should eq("visa")
      listed["recipients"][0]["email"].as_s.should eq("a@example.com")
    end

    it "hides them from GET /joobq/jobs/retrying" do
      job = build_job.call
      job.retrying!
      JoobQ.store.as(RedisStore).redis.zadd(RedisStore::DELAYED_SET, (Time.utc.to_unix_ms + 60_000).to_f, job.to_json)

      status, body = get.call("/joobq/jobs/retrying")

      status.should eq(200)
      JSON.parse(body)["count"].as_i.should eq(1)
      refute_secrets.call(body)
      JSON.parse(body)["jobs"][0]["password"].as_s.should eq(PayloadRedaction::REDACTED)
    end

    {"/joobq/errors/recent", "/joobq/errors/by-type?type=unknown_error", "/joobq/errors/by-queue?queue=example"}.each do |path|
      it "hides them from the job data of #{path}" do
        job = build_job.call
        context = ErrorContext.from_exception(job, Queue(PaymentJob).new("example", 1), RuntimeError.new("boom"), "worker-1")
        JoobQ.error_monitor.record_error(context)

        status, body = get.call(path)

        status.should eq(200)
        refute_secrets.call(body)
        entry = JSON.parse(body).as_a.first
        entry["error_message"].as_s.should eq("boom")
        stored = JSON.parse(entry["job_data"].as_s)
        stored["password"].as_s.should eq(PayloadRedaction::REDACTED)
        stored["order_id"].as_i.should eq(4242)
      end
    end

    it "never shows an encrypted property decrypted" do
      job = build_job.call
      job.dead!
      sealed_json = job.to_json
      sealed_json.should_not contain(sealed_plain)
      JoobQ.store.as(RedisStore).redis.zadd(Keys::DEAD_LETTER, 1_i64, sealed_json)

      body = get.call("/joobq/jobs/dead")[1]

      body.should_not contain(sealed_plain)
      JSON.parse(body)["jobs"][0]["sealed_note"].as_s.should_not eq(sealed_plain)
    end

    it "matches names without regard to case, dashes or spaces, by substring" do
      any = JSON.parse(%({"Client-Secret":"a","API KEY":"b","userPassword":"c","dbPasswd":"d","author":"e","name":"f"}))

      redacted = PayloadRedaction.redact(any)

      redacted["Client-Secret"].as_s.should eq(PayloadRedaction::REDACTED)
      redacted["API KEY"].as_s.should eq(PayloadRedaction::REDACTED)
      redacted["dbPasswd"].as_s.should eq(PayloadRedaction::REDACTED)
      redacted["author"].as_s.should eq("e")
      redacted["name"].as_s.should eq("f")
    end

    it "uses the configured list instead of the default" do
      JoobQ.config.redacted_payload_keys = ["order_id"]
      job = build_job.call
      job.dead!
      JoobQ.store.as(RedisStore).redis.zadd(Keys::DEAD_LETTER, 1_i64, job.to_json)

      listed = JSON.parse(get.call("/joobq/jobs/dead")[1])["jobs"].as_a.first

      listed["order_id"].as_s.should eq(PayloadRedaction::REDACTED)
      listed["password"].as_s.should eq(plain_password)
    end

    it "shows payloads as stored once redact_api_payloads is off" do
      JoobQ.config.redact_api_payloads = false
      job = build_job.call
      job.dead!
      JoobQ.store.as(RedisStore).redis.zadd(Keys::DEAD_LETTER, 1_i64, job.to_json)

      body = get.call("/joobq/jobs/dead")[1]

      body.should contain(plain_password)
      body.should_not contain(sealed_plain)
    end

    it "leaves the stored job untouched, so a retry still carries the real arguments" do
      job = build_job.call
      job.dead!
      redis = JoobQ.store.as(RedisStore).redis
      redis.zadd(Keys::DEAD_LETTER, 1_i64, job.to_json)

      get.call("/joobq/jobs/dead")

      redis.zrange(Keys::DEAD_LETTER, 0, -1).first.to_s.should contain(plain_password)
    end

    it "does not raise on a stored entry that is not JSON" do
      PayloadRedaction.redact_json("not json").should eq("not json")
    end
  end

  describe "allow_plaintext_payloads" do
    it "defaults to false: a worker refuses a plain value in an encrypted property unless the operator opts out" do
      Configure.new.allow_plaintext_payloads?.should be_false
    end
  end
end
