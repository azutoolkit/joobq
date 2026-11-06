require "joobq"

reader = "reader-token-0123456789abcdef0123456789"
operator = "operator-token-0123456789abcdef012345678"
policy = JoobQ::ManagementPolicy.new({
  reader   => JoobQ::ManagementPolicy::Role::Reader,
  operator => JoobQ::ManagementPolicy::Role::Operator,
})
server = HTTP::Server.new([JoobQ::APIHandler.new(policy)])
address = server.bind_tcp("127.0.0.1", 0)
spawn { server.listen }

def call(address, method, path, role = nil, token = nil)
  headers = HTTP::Headers.new
  headers["Authorization"] = "Bearer #{token}" if token
  status = HTTP::Client.exec(method, "http://#{address}#{path}", headers).status_code
  puts "#{method} #{path} as #{role || "anonymous"}: #{status}"
end

call(address, "GET", "/joobq/health/check")
call(address, "GET", "/joobq/health/check", "reader", reader)
call(address, "POST", "/joobq/jobs/retrying", "reader", reader)
call(address, "POST", "/joobq/pipeline/stats/reset", "operator", operator)
server.close
