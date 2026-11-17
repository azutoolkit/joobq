require "./spec_helper"

# The seam: JoobQ::APIServer.redis_probe (class-level getter/setter; the default pings the store's Redis and raises
# when it does not answer; setting it forgets the cached answer), JoobQ::APIServer.readiness (the Redis answer cached
# for READINESS_TTL, one probe at a time) and JoobQ::APIServer.reset_readiness_cache. /healthz never calls the probe;
# /readyz serves `readiness`: 200 when ready, else 503.
# Shutdown is simulated by setting JoobQ's @@shut_down flag (as spec/shutdown_spec.cr does) and restored in ensure.
module JoobQ
  def self.probe_spec_shut_down(value : Bool) : Nil
    @@shut_down.set(value)
  end
end

module JoobQ
  describe "liveness and readiness probes" do
    token = "t" * 32
    policy = ManagementPolicy.new({token => ManagementPolicy::Role::Admin})

    # No Authorization header: probes must be reachable by an orchestrator, even under a real ManagementPolicy.
    get = ->(path : String) do
      io = IO::Memory.new
      context = HTTP::Server::Context.new(HTTP::Request.new("GET", path), HTTP::Server::Response.new(io))
      APIHandler.new(policy).call(context)
      context.response.flush
      {context.response.status_code, context.response.headers["Content-Type"]?, context.response.@io.to_s}
    end
    body = ->(raw : String) { JSON.parse(raw[(raw.index("\r\n\r\n") || -4) + 4..]) }

    # Status, headers and body of a request without credentials.
    answer = ->(method : String, path : String) do
      io = IO::Memory.new
      context = HTTP::Server::Context.new(HTTP::Request.new(method, path), HTTP::Server::Response.new(io))
      APIHandler.new(policy).call(context)
      context.response.close
      {context.response.status_code, context.response.headers.to_h, io.to_s}
    end

    before_each { APIServer.reset_readiness_cache }

    it "refuses near-miss probe paths and methods exactly as an unknown route" do
      refused = answer.call("GET", "/joobq/no-such-route")
      refused[0].should eq 401
      [{"POST", "/healthz"}, {"POST", "/readyz"}, {"GET", "/healthz/"}, {"GET", "//healthz"}, {"GET", "/HEALTHZ"},
       {"GET", "/%68ealthz"}, {"GET", "/joobq/health/check"}].each do |method, path|
        got = answer.call(method, path)
        {method, path, got[0], got[1], got[2]}.should eq({method, path, refused[0], refused[1], refused[2]})
      end
    end

    it "answers HEAD /readyz with no body and the length of the GET body" do
      _, _, get_raw = answer.call("GET", "/readyz")
      status, headers, raw = answer.call("HEAD", "/readyz")
      status.should eq 200
      raw.should end_with("\r\n\r\n")
      get_body = get_raw[get_raw.index!("\r\n\r\n") + 4..]
      headers["Content-Length"].should eq [get_body.bytesize.to_s]
      headers["Cache-Control"].should eq ["no-store"]
    end

    it "pings Redis once for calls within the cache window, and again after a reset" do
      original = APIServer.redis_probe
      pings = 0
      APIServer.redis_probe = -> { pings += 1; nil }
      begin
        get.call("/readyz")[0].should eq 200
        get.call("/readyz")[0].should eq 200
        APIServer.readiness[:ready].should be_true
        pings.should eq 1
        APIServer.reset_readiness_cache
        get.call("/readyz")[0].should eq 200
        pings.should eq 2
      ensure
        APIServer.redis_probe = original
      end
    end

    it "shares one ping between concurrent readiness checks" do
      original = APIServer.redis_probe
      pings = 0
      release = Channel(Nil).new
      APIServer.redis_probe = -> { pings += 1; release.receive?; nil }
      done = Channel(Bool).new
      begin
        3.times { spawn { done.send(APIServer.readiness[:ready]) } }
        Fiber.yield
        release.close # frees every waiting probe, so a probe per call would count 3 instead of hanging
        3.times { done.receive.should be_true }
        pings.should eq 1
      ensure
        APIServer.redis_probe = original
      end
    end

    it "GET /healthz is 200 {status: ok} as JSON" do
      status, type, raw = get.call("/healthz")
      status.should eq 200
      type.to_s.should contain "application/json"
      body.call(raw).should eq JSON.parse(%({"status":"ok"}))
    end

    it "GET /healthz does not touch Redis and survives shutdown" do
      original = APIServer.redis_probe
      APIServer.redis_probe = -> { raise "healthz must not ping Redis" }
      JoobQ.probe_spec_shut_down(true)
      begin
        get.call("/healthz")[0].should eq 200
      ensure
        JoobQ.probe_spec_shut_down(false)
        APIServer.redis_probe = original
      end
    end

    it "GET /readyz is 200 ready when Redis answers" do
      status, type, raw = get.call("/readyz")
      status.should eq 200
      type.to_s.should contain "application/json"
      body.call(raw).should eq JSON.parse(%({"status":"ready","checks":{"redis":"ok","shutdown":false}}))
    end

    it "GET /readyz is 503 not_ready when Redis does not answer" do
      original = APIServer.redis_probe
      APIServer.redis_probe = -> { raise "connection refused" }
      begin
        APIServer.readiness[:ready].should be_false
        status, _, raw = get.call("/readyz")
        status.should eq 503
        json = body.call(raw)
        json["status"].as_s.should eq "not_ready"
        json["checks"]["redis"].as_s.should eq "unreachable"
      ensure
        APIServer.redis_probe = original
      end
    end

    it "GET /readyz is 503 while JoobQ shuts down" do
      JoobQ.probe_spec_shut_down(true)
      begin
        status, _, raw = get.call("/readyz")
        status.should eq 503
        body.call(raw)["checks"]["shutdown"].as_bool.should be_true
      ensure
        JoobQ.probe_spec_shut_down(false)
      end
    end

    it "/joobq/health/check still answers {status: OK} with credentials" do
      io = IO::Memory.new
      headers = HTTP::Headers{"Authorization" => "Bearer #{token}"}
      context = HTTP::Server::Context.new(HTTP::Request.new("GET", "/joobq/health/check", headers), HTTP::Server::Response.new(io))
      APIHandler.new(policy).call(context)
      context.response.flush
      context.response.status_code.should eq 200
      io.to_s.should contain %({"status":"OK"})
    end
  end
end
