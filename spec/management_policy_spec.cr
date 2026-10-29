require "./spec_helper"

private def management_request(policy, method, token, body = nil, path = "/joobq/queues")
  headers = HTTP::Headers.new
  headers["Authorization"] = "Bearer #{token}" if token
  request = HTTP::Request.new(method, path, headers, body)
  response = HTTP::Server::Response.new(IO::Memory.new)
  context = HTTP::Server::Context.new(request, response)
  {policy.authorize(context), response.status_code}
end

describe JoobQ::ManagementPolicy do
  it "requires authentication and separates readers, operators and administrators" do
    reader, operator, admin = "r" * 32, "o" * 32, "a" * 32
    policy = JoobQ::ManagementPolicy.new({reader => JoobQ::ManagementPolicy::Role::Reader,
                                          operator => JoobQ::ManagementPolicy::Role::Operator, admin => JoobQ::ManagementPolicy::Role::Admin})
    management_request(policy, "GET", nil).should eq({false, 401})
    management_request(policy, "GET", "x" * 32).should eq({false, 401})
    management_request(policy, "GET", reader)[0].should be_true
    management_request(policy, "POST", reader).should eq({false, 403})
    management_request(policy, "POST", operator)[0].should be_true
    management_request(policy, "DELETE", operator).should eq({false, 403})
    management_request(policy, "DELETE", admin)[0].should be_true
    management_request(policy, "POST", operator, path: "/joobq/pipeline/stats/reset").should eq({false, 403})
  end

  it "rejects oversized bodies and insecure token configuration" do
    token = "t" * 32
    policy = JoobQ::ManagementPolicy.new({token => JoobQ::ManagementPolicy::Role::Admin}, max_body: 8)
    management_request(policy, "POST", token, "123456789").should eq({false, 413})
    expect_raises(ArgumentError) { JoobQ::ManagementPolicy.new({"short" => JoobQ::ManagementPolicy::Role::Admin}) }
  end
end
