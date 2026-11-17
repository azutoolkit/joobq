require "./spec_helper"

# Assumed seam (not implemented yet):
#   JoobQ::APIServer.redis_probe : -> Nil  (class-level getter/setter; default pings the store's Redis, raises when
#   it does not answer) and JoobQ::APIServer.readiness : NamedTuple(ready: Bool, checks: NamedTuple(redis: String,
#   shutdown: Bool)). /healthz never calls the probe; /readyz serves `readiness`: 200 when ready, else 503.
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
