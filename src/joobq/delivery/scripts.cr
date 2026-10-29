require "digest/sha1"

module JoobQ::Delivery
  # EVALSHA is safe to retry only after the server explicitly reports NOSCRIPT:
  # that response proves no script ran. Never replay a timeout/lost response.
  class Script
    getter source : String
    getter sha : String

    def initialize(@source)
      @sha = Digest::SHA1.hexdigest(source)
    end

    def call(redis : Redis::PooledClient, keys : Array(String), args : Array(String))
      redis.evalsha(sha, keys, args)
    rescue ex : Redis::Error
      raise ex unless ex.message.try(&.starts_with?("NOSCRIPT "))
      redis.eval(source, keys, args)
    end
  end

  module Scripts
    # cjson encodes at most 14 significant digits. Payload is an OPAQUE STRING,
    # never decoded as business JSON. Envelopes outside this exact integer range
    # fall back to Crystal's Int64 CAS path without mutation or rounding.
    COMMON = <<-LUA
      cjson.encode_number_precision(14)
      local function clock()
        local t = redis.call('TIME')
        return tonumber(t[1]) * 1000 + math.floor(tonumber(t[2]) / 1000)
      end
      local fields = {schema=true,id=true,payload=true,digest=true,state=true,attempt=true,
        token=true,owner=true,due_at=true,lease_until=true,traceparent=true}
      local states = {ready=true,leased=true,scheduled=true,completed=true,dead=true}
      local function integer(n)
        return type(n) == 'number' and n >= 0 and n < 99999999999999 and n == math.floor(n)
      end
      local function envelope(raw, id)
        local ok, e = pcall(cjson.decode, raw)
        if not ok or type(e) ~= 'table' or e.schema ~= 1 or e.id ~= id
          or type(e.payload) ~= 'string' or type(e.digest) ~= 'string'
          or #e.digest ~= 64 or not string.match(e.digest, '^[0-9a-f]+$')
          or not states[e.state] or not integer(e.attempt)
          or not integer(e.due_at) or not integer(e.lease_until) then return nil end
        for k, _ in pairs(e) do if not fields[k] then return nil end end
        if e.traceparent ~= nil and e.traceparent ~= cjson.null then
          if type(e.traceparent) ~= 'string' or #e.traceparent ~= 55
            or not string.match(e.traceparent, '^00%-[0-9a-f]+%-[0-9a-f]+%-[0-9a-f]+$')
            or string.sub(e.traceparent, 36, 36) ~= '-'
            or string.sub(e.traceparent, 53, 53) ~= '-'
            or string.sub(e.traceparent, 4, 35) == string.rep('0',32)
            or string.sub(e.traceparent, 37, 52) == string.rep('0',16) then return nil end
        end
        if (e.token ~= nil and e.token ~= cjson.null and type(e.token) ~= 'string')
          or (e.owner ~= nil and e.owner ~= cjson.null and type(e.owner) ~= 'string') then return nil end
        if e.state == 'leased' and (type(e.token) ~= 'string' or type(e.owner) ~= 'string' or e.lease_until <= 0) then return nil end
        return e
      end
      local function write(e)
        local raw = cjson.encode(e)
        -- Canonical intent MUST precede derived indexes; Lua errors do not roll back.
        redis.call('HSET', KEYS[1], e.id, raw)
        if e.state == 'ready' or e.state == 'scheduled' then
          redis.call('ZADD', KEYS[2], e.due_at, e.id)
        else
          redis.call('ZREM', KEYS[2], e.id)
        end
        if e.state == 'leased' then
          redis.call('ZADD', KEYS[3], e.lease_until, e.id)
        else
          redis.call('ZREM', KEYS[3], e.id)
        end
        return raw
      end
    LUA

    ADMIT_BODY = <<-LUA
      local old = redis.call('HGET', KEYS[1], ARGV[1])
      if old then return {1, old} end
      if redis.call('HLEN', KEYS[1]) >= tonumber(ARGV[4]) then return {-1} end
      local e = envelope(ARGV[2], ARGV[1])
      if not e then return {-2} end
      e.due_at = clock() + tonumber(ARGV[3])
      if not integer(e.due_at) then return {-2} end
      write(e)
      return {3, e.due_at}
    LUA

    ADMIT = Script.new(COMMON + ADMIT_BODY)

    ADMIT_MANY = Script.new(COMMON + "\nlocal function one(ARGV)\n" + ADMIT_BODY + "\nend\n" + <<-LUA)
      local results = {}
      for i = 3, #ARGV, 2 do
        results[#results + 1] = one({ARGV[i], ARGV[i+1], ARGV[1], ARGV[2]})
      end
      return results
    LUA

    CLAIM_MANY = Script.new(COMMON + <<-LUA)
      if redis.call('EXISTS', KEYS[4]) == 1 then return {} end
      local now = clock()
      local results = {}
      local bytes = 0
      local ids = redis.call('ZRANGEBYSCORE', KEYS[2], '-inf', now, 'LIMIT', 0, tonumber(ARGV[4]))
      for _, id in ipairs(ids) do
        local raw = redis.call('HGET', KEYS[1], id)
        if raw then
          local e = envelope(raw, id)
          if not e or not integer(e.attempt + 1) or not integer(now + tonumber(ARGV[3])) then
            results[#results + 1] = {-2}
          elseif (e.state == 'ready' or e.state == 'scheduled') and e.due_at <= now then
            if bytes + #e.payload > tonumber(ARGV[5]) then break end
            bytes = bytes + #e.payload
            e.state = 'leased'
            e.attempt = e.attempt + 1
            e.owner = ARGV[1]
            e.token = ARGV[2] .. ':' .. tostring(#results + 1)
            e.lease_until = now + tonumber(ARGV[3])
            write(e)
            results[#results + 1] = {1, id, raw, e.attempt, e.token}
          else
            redis.call('ZREM', KEYS[2], id)
          end
        else
          redis.call('ZREM', KEYS[2], id)
        end
      end
      return results
    LUA

    CLAIM = Script.new(COMMON + <<-LUA)
      if redis.call('EXISTS', KEYS[4]) == 1 then return {0} end
      local now = clock()
      local ids = redis.call('ZRANGEBYSCORE', KEYS[2], '-inf', now, 'LIMIT', 0, 100)
      for _, id in ipairs(ids) do
        local raw = redis.call('HGET', KEYS[1], id)
        if raw then
          local e = envelope(raw, id)
          if not e then return {-2} end
          if (e.state == 'ready' or e.state == 'scheduled') and e.due_at <= now then
            e.state = 'leased'
            e.attempt = e.attempt + 1
            e.owner = ARGV[1]
            e.token = ARGV[2]
            e.lease_until = now + tonumber(ARGV[3])
            if not integer(e.lease_until) then return {-2} end
            write(e)
            return {1, id, raw, e.attempt}
          end
          -- An orphan index must not hide healthy work behind the first page.
          redis.call('ZREM', KEYS[2], id)
        else
          redis.call('ZREM', KEYS[2], id)
        end
      end
      return {0}
    LUA

    QUARANTINE_CLAIM = Script.new(COMMON + <<-LUA)
      local raw = redis.call('HGET', KEYS[1], ARGV[1])
      if not raw then return 0 end
      local ok, e = pcall(cjson.decode, raw)
      if not ok or e.state ~= 'leased' or e.token ~= ARGV[2] or e.owner ~= ARGV[3]
        or e.attempt ~= tonumber(ARGV[4]) then return 0 end
      -- The client detected a checksum violation before executing the handler.
      -- Restore the original forensic bytes only while this claim still owns it.
      redis.call('HSET', KEYS[1], ARGV[1], ARGV[5])
      redis.call('HSET', KEYS[5], ARGV[1], ARGV[5])
      redis.call('ZREM', KEYS[2], ARGV[1])
      redis.call('ZREM', KEYS[3], ARGV[1])
      return 1
    LUA

    TRANSITION_BODY = <<-LUA
      local raw = redis.call('HGET', KEYS[1], ARGV[1])
      if not raw then return {0} end
      local e = envelope(raw, ARGV[1])
      if not e then return {-2} end
      -- Payload and digest are compared with the validated claim, so corruption
      -- after claiming cannot silently receive a successful acknowledgment.
      if e.payload ~= ARGV[7] or e.digest ~= ARGV[8] then return {-2} end
      local own = e.token == ARGV[2] and e.owner == ARGV[3] and e.attempt == tonumber(ARGV[4])
      if own and e.state == ARGV[5] and ARGV[5] ~= 'leased' then return {2} end
      local now = clock()
      if not own or e.state ~= 'leased' or e.lease_until <= now then return {0} end
      if ARGV[5] == 'leased' then
        if redis.call('EXISTS', KEYS[4]) == 1 then return {0} end
        e.lease_until = now + tonumber(ARGV[6])
      else
        e.state = ARGV[5]
        e.lease_until = 0
        e.due_at = now + tonumber(ARGV[6])
      end
      if not integer(e.lease_until) or not integer(e.due_at) then return {-2} end
      write(e)
      return {1}
    LUA
    TRANSITION = Script.new(COMMON + TRANSITION_BODY)

    SETTLE_MANY = Script.new(COMMON + "\nlocal function one(ARGV)\n" + TRANSITION_BODY + "\nend\n" + <<-LUA)
      local results = {}
      for i = 1, #ARGV, 8 do
        results[#results + 1] = one({ARGV[i], ARGV[i+1], ARGV[i+2], ARGV[i+3],
          ARGV[i+4], ARGV[i+5], ARGV[i+6], ARGV[i+7]})[1]
      end
      return results
    LUA
  end
end
