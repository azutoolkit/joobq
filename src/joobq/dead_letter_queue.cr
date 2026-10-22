require "json"

module JoobQ
  # Operator view of the dead-letter set: paged reads, redrive and purge.
  # Each state change is one atomic Lua step, so two operators can never redrive
  # or purge the same entry twice.
  class DeadLetterQueue
    KEY    = "joobq:dead_letter"
    COUNTS = "joobq:dead_letter:counts" # entries per queue, kept by the scripts below
    CHUNK  = 200

    # Entries whose JSON has no queue are counted under this name, so the counts always add up to the set.
    UNKNOWN = ""

    # The queue an entry belongs to, read the way `parse` reads it: from the entry itself, never from the caller.
    QUEUE_OF = <<-LUA
      local function queue_of(member)
        local ok, job = pcall(cjson.decode, member)
        if ok and type(job) == 'table' and type(job.queue) == 'string' then return job.queue end
        return ''
      end
    LUA

    # Adds members (ARGV[2..], scored ARGV[1]) to the set. A member that is already there is not counted again.
    ADD = QUEUE_OF + <<-LUA
      local added = 0
      for i = 2, #ARGV do
        if redis.call('ZADD', KEYS[1], ARGV[1], ARGV[i]) == 1 then
          redis.call('HINCRBY', KEYS[2], queue_of(ARGV[i]), 1)
          added = added + 1
        end
      end
      return added
    LUA

    # Removes members (ARGV) from the set and from the counts; returns how many were there.
    REMOVE = QUEUE_OF + <<-LUA
      local removed = 0
      for _, member in ipairs(ARGV) do
        if redis.call('ZREM', KEYS[1], member) == 1 then
          redis.call('HINCRBY', KEYS[2], queue_of(member), -1)
          removed = removed + 1
        end
      end
      return removed
    LUA

    # The set's size and the counts, read together; and the counts rebuilt from the set (for data written
    # before they existed). The rebuild blocks Redis for as long as the scan takes, so it runs only when the
    # two disagree.
    READ = <<-LUA
      return {redis.call('ZCARD', KEYS[1]), redis.call('HGETALL', KEYS[2])}
    LUA

    RECOUNT = QUEUE_OF + <<-LUA
      redis.call('DEL', KEYS[2])
      for _, member in ipairs(redis.call('ZRANGE', KEYS[1], 0, -1)) do
        redis.call('HINCRBY', KEYS[2], queue_of(member), 1)
      end
      return 1
    LUA

    # Moves one entry back onto its queue; 0 when someone else got there first, -1 when the queue's key holds
    # something that is not a list (nothing is touched then: a failure after the ZREM would lose the entry).
    REDRIVE = <<-LUA
      local kind = redis.call('TYPE', KEYS[2]).ok
      if kind ~= 'list' and kind ~= 'none' then
        return -1
      end
      if redis.call('ZREM', KEYS[1], ARGV[1]) == 1 then
        redis.call('RPUSH', KEYS[2], ARGV[2])
        redis.call('DEL', KEYS[3])
        redis.call('HINCRBY', KEYS[4], ARGV[3], -1) -- ARGV[3]: the entry's own queue
        return 1
      end
      return 0
    LUA

    struct Entry
      include JSON::Serializable

      getter jid : String
      getter queue : String
      getter failed_at : Int64
      getter error : String?
      getter job : JSON::Any

      @[JSON::Field(ignore: true)]
      getter member : String = ""

      def initialize(@jid, @queue, @failed_at, @error, @job, @member)
      end

      # Jobs that could not even be parsed are stored as stubs holding only a
      # truncated copy of the original; running those again would just fail again.
      def redrivable? : Bool
        job["original_job_data"]?.nil?
      end
    end

    # What happened to each requested jid.
    struct Outcome
      include JSON::Serializable

      getter succeeded : Int32
      getter missing : Array(String)
      getter unredrivable : Array(String)
      getter conflicted : Array(String)

      def initialize(@succeeded, @missing = [] of String, @unredrivable = [] of String,
                     @conflicted = [] of String)
      end
    end

    def initialize(@redis : Redis::PooledClient = RedisStore.instance.redis)
    end

    # Every writer to the set goes through here, so the counts stay exact. Members already present are not
    # counted twice; returns how many were new.
    def self.add(redis : Redis::PooledClient, score : Int64, members : Array(String)) : Int64
      return 0_i64 if members.empty?

      redis.eval(ADD, [KEY, COUNTS], [score.to_s] + members).as(Int64)
    end

    def count(queue : String? = nil) : Int64
      queue ? (counts[queue]? || 0_i64) : @redis.zcard(KEY)
    end

    # Entries per queue without reading them. If the counts do not add up to the set (entries written by code
    # that predates them), they are rebuilt once.
    def counts : Hash(String, Int64)
      stored = read_counts
      return stored unless stored.nil?

      @redis.eval(RECOUNT, [KEY, COUNTS])
      read_counts || {} of String => Int64
    end

    # Newest first. `queue` filters; `offset`/`limit` page through the matches.
    def page(offset : Int32 = 0, limit : Int32 = 50, queue : String? = nil) : Array(Entry)
      offset = offset.clamp(0, Int32::MAX)
      limit = limit.clamp(0, Int32::MAX - offset)
      return [] of Entry if limit == 0
      return read(offset, limit) unless queue

      matches = [] of Entry
      skipped = 0
      each_entry do |entry|
        next unless entry.queue == queue
        (skipped += 1; next) if skipped < offset

        matches << entry
        break if matches.size == limit
      end
      matches
    end

    def find(jid : String) : Entry?
      locate([jid]).first?
    end

    def redrive(jids : Array(String)) : Outcome
      apply(jids) do |entry, tally|
        if !entry.redrivable?
          tally.unredrivable << entry.jid
        else
          case @redis.eval(REDRIVE, [KEY, entry.queue, "joobq:retry_lock:#{entry.jid}", COUNTS], [entry.member, fresh_payload(entry), entry.queue])
          when  1 then tally.succeeded += 1
          when -1 then tally.unredrivable << entry.jid # its queue name is not a queue
          else         tally.conflicted << entry.jid
          end
        end
      end
    end

    def purge(jids : Array(String)) : Outcome
      apply(jids) do |entry, tally|
        if @redis.eval(REMOVE, [KEY, COUNTS], [entry.member]) == 1
          tally.succeeded += 1
        else
          tally.conflicted << entry.jid
        end
      end
    end

    def purge_all(queue : String? = nil) : Int32
      members = [] of String
      each_entry { |entry| members << entry.member if queue.nil? || entry.queue == queue }
      members.each_slice(CHUNK).sum { |slice| @redis.eval(REMOVE, [KEY, COUNTS], slice).as(Int64).to_i }
    end

    # nil when the counts do not add up to the set's size.
    private def read_counts : Hash(String, Int64)?
      size, flat = @redis.eval(READ, [KEY, COUNTS]).as(Array)
      stored = flat.as(Array).each_slice(2).to_h { |(queue, count)| {queue.to_s, count.to_s.to_i64} }
      return unless stored.values.sum == size.as(Int64)

      stored.reject { |queue, count| queue == UNKNOWN || count <= 0 }
    end

    private class Tally
      property succeeded = 0
      getter unredrivable = [] of String
      getter conflicted = [] of String
    end

    private def apply(jids : Array(String), & : Entry, Tally ->) : Outcome
      found = locate(jids)
      tally = Tally.new
      found.each { |entry| yield entry, tally }
      Outcome.new(tally.succeeded, jids - found.map(&.jid), tally.unredrivable, tally.conflicted)
    end

    # Entries for the given jids, stopping the scan as soon as all are found.
    private def locate(jids : Array(String)) : Array(Entry)
      wanted = jids.to_set
      found = [] of Entry
      each_entry do |entry|
        found << entry if wanted.includes?(entry.jid)
        break if found.size == wanted.size
      end
      found
    end

    private def read(offset : Int32, limit : Int32) : Array(Entry)
      parse_all(@redis.zrevrange(KEY, offset, offset + limit - 1, with_scores: true))
    end

    # Newest first, in chunks so a huge set is never loaded whole.
    private def each_entry(& : Entry ->) : Nil
      start = 0
      loop do
        chunk = parse_all(@redis.zrevrange(KEY, start, start + CHUNK - 1, with_scores: true))
        break if chunk.empty? && @redis.zcard(KEY) <= start

        chunk.each { |entry| yield entry }
        start += CHUNK
      end
    end

    private def parse_all(raw : Array) : Array(Entry)
      raw.each_slice(2).compact_map { |(member, score)| parse(member.to_s, score.to_s.to_f.to_i64) }.to_a
    end

    private def parse(member : String, score : Int64) : Entry?
      job = JSON.parse(member)
      Entry.new(
        jid: job["jid"].as_s, queue: job["queue"].as_s, failed_at: score,
        error: job["error"]?.try(&.as_h?).try(&.["message"]?).try(&.as_s?), job: job, member: member)
    rescue JSON::ParseException | KeyError | TypeCastError
      nil
    end

    # The job as it should run again: full retry budget, new expiry, no error.
    private def fresh_payload(entry : Entry) : String
      job = entry.job.as_h.dup
      job["status"] = JSON::Any.new("enqueued")
      job["expires"] = JSON::Any.new(JoobQ.config.expires.from_now.to_unix_ms)
      job["retries"] = job["max_retries"]? || JSON::Any.new(JoobQ.config.retries.to_i64)
      job["error"] = JSON::Any.new(nil)
      JSON::Any.new(job).to_json
    end
  end
end
