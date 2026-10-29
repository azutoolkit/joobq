require "http/server"
require "digest/sha256"

module JoobQ
  # Authentication and authorization are applied before reading a request body or
  # invoking an operator action. Store only token digests; never log credentials.
  class ManagementPolicy
    enum Role
      Reader
      Operator
      Admin
    end

    @tokens : Hash(String, Role)

    def initialize(tokens : Hash(String, Role), @max_body : Int32 = 1_048_576)
      raise ArgumentError.new("management tokens are required") if tokens.empty?
      raise ArgumentError.new("body limit must be positive") unless @max_body > 0
      @tokens = {} of String => Role
      tokens.each do |token, role|
        raise ArgumentError.new("management tokens must be at least 32 bytes") unless token.bytesize >= 32
        @tokens[Digest::SHA256.hexdigest(token)] = role
      end
    end

    def self.from_env : self
      tokens = {} of String => Role
      {"READER" => Role::Reader, "OPERATOR" => Role::Operator, "ADMIN" => Role::Admin}.each do |name, role|
        if token = ENV["JOOBQ_API_#{name}_TOKEN"]?.presence
          tokens[token] = role
        end
      end
      new(tokens)
    end

    def authorize(context : HTTP::Server::Context) : Bool
      authorization = context.request.headers["Authorization"]?
      unless authorization && authorization.starts_with?("Bearer ") && authorization.bytesize <= 4096
        return reject(context, 401)
      end
      digest = Digest::SHA256.hexdigest(authorization.byte_slice(7))
      role = nil.as(Role?)
      @tokens.each { |known, candidate| role = candidate if secure_equal(known, digest) }
      return reject(context, 401) unless role
      method = context.request.method
      required = if method == "GET" || method == "HEAD"
                   Role::Reader
                 elsif method == "DELETE" || context.request.path.includes?("/reset") || context.request.path.includes?("/config")
                   Role::Admin
                 else
                   Role::Operator
                 end
      return reject(context, 403) if role.value < required.value
      if length = context.request.content_length
        return reject(context, 413) if length > @max_body
      end
      if body = context.request.body
        bounded = IO::Memory.new
        IO.copy(body, bounded, @max_body.to_i64 + 1)
        return reject(context, 413) if bounded.size > @max_body
        context.request.body = bounded.to_s
      end
      Log.info &.emit("Management request authorized", role: role.to_s, method: method,
        path: context.request.path, audit_id: UUID.random.to_s)
      true
    end

    private def reject(context, status) : Bool
      context.response.status_code = status
      context.response.headers["Cache-Control"] = "no-store"
      context.response.headers["WWW-Authenticate"] = "Bearer" if status == 401
      context.response.content_type = "application/json"
      context.response.print({error: status == 413 ? "request_too_large" : "access_denied"}.to_json)
      false
    end

    private def secure_equal(left : String, right : String) : Bool
      return false unless left.bytesize == right.bytesize
      difference = 0_u8
      left.to_slice.zip(right.to_slice) { |a, b| difference |= a ^ b }
      difference == 0
    end
  end
end
