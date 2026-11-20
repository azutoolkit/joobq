module JoobQ
  # Another process is live, so its keys are not moved from under it.
  class KeyspaceMigrationError < Exception
  end

  # Moves a 0.6 keyspace into `Keys::PREFIX`. 0.6 kept the waiting jobs of a queue under the bare queue name and its
  # other keys under `joobq:` with no version.
  module Keyspace
    # *renamed*: keys moved as they were. *merged*: old keys folded into a new key that already existed (the new
    # version had created it), or dropped as stale. *skipped*: old keys left where they are, listed by name, because
    # the new key is of another type.
    record Report, renamed : Int32, skipped : Array(String), merged : Int32 = 0

    OLD_PREFIX = "joobq:"
    OLD_OWNERS = "joobq:processing-owners"

    # The old name of every key that moves unchanged apart from the prefix (a family is the text after `joobq:`).
    private FAMILIES = /\A(processing|processing-owners|delayed_jobs|dead_letter|dead_letter:counts|error_counts|recent_errors|error_index|workers|events|events:trim_lock|failed_jobs|stats:.+|retry_lock:.+|worker:.+|delivery-bridge:.+)\z/
    # What 0.6 kept only to know who was alive: when the new key exists, the old one is stale and is dropped.
    private TRANSIENT = /\A(processing-owners|workers|worker:.+|events|events:trim_lock|delivery-bridge:.+)\z/
    # Counters that add up when both namespaces have them
    private COUNTERS = /\A(stats:.+|error_counts|dead_letter:counts)\z/
    private FLAG     = /\Aqueue:(.+):(paused|config)\z/

    # The new name of a 0.6 `joobq:` key, or nil for one that is not moved (the pub/sub channel, the probe, anything
    # unknown, and every key already under `joobq:v1:`).
    def self.new_name(old : String) : String?
      return nil unless old.starts_with?(OLD_PREFIX) && !old.starts_with?("#{Keys::PREFIX}:")

      family = old.lchop(OLD_PREFIX)
      if (flag = FLAG.match(family))
        "#{Keys::PREFIX}:#{flag[2]}:#{flag[1]}"
      elsif family.starts_with?("processing:") || FAMILIES.matches?(family)
        "#{Keys::PREFIX}:#{family}"
      end
    end

    # {old, new} for every 0.6 key present: the bare lists of *queues*, and the `joobq:` keys.
    def self.legacy_keys(redis : Redis::PooledClient, queues : Array(String)) : Array({String, String})
      found = queues.select { |name| redis.type(name) == "list" }.map { |name| {name, Keys.queue(name)} }
      cursor = "0"
      loop do
        reply = redis.scan(cursor, match: "#{OLD_PREFIX}*", count: 1000)
        cursor = reply[0].as(String)
        reply[1].as(Array).each do |key|
          old = key.as(String)
          found << {old, new_name(old).not_nil!} if new_name(old)
        end
        break if cursor == "0"
      end
      found.uniq
    end

    def self.migrate!(store : RedisStore, queues : Array(String)) : Report
      others = live_other_owners(store)
      unless others.empty?
        raise KeyspaceMigrationError.new("processes are live (#{others.to_a.sort.join(", ")}); stop them before migrating the keyspace")
      end

      renamed = merged = 0
      skipped = [] of String
      legacy_keys(store.redis, queues).each do |(old, new)|
        if store.redis.renamenx(old, new) == 1
          renamed += 1
        elsif merge(store.redis, old, new)
          merged += 1
        else
          skipped << old
          Log.warn &.emit("Keyspace migration left a key: the new name is of another type", old: old, new: new)
        end
      rescue ex : Redis::Error
        # the key went away (another migration) between the scan and the rename
        raise ex unless ex.message.try(&.includes?("no such key"))
      end
      Log.info &.emit("Keyspace migrated to #{Keys::PREFIX}", renamed: renamed, merged: merged, skipped: skipped.size)
      Report.new(renamed, skipped, merged)
    end

    # The new version created *new* before the migration ran (its first heartbeat, a queue start, an enqueue): folds
    # *old* into it and deletes *old*, or returns false (nothing changed) when the two are of different types.
    # Transient keys are stale and dropped; sorted sets are united (the later score wins); counters add up; lists
    # put the old items at the head of the new list, in their order, so no waiting job is stranded; any other value
    # keeps the new one.
    private def self.merge(redis : Redis::PooledClient, old : String, new : String) : Bool
      # nil for a bare queue list: its name is the user's, so a queue called `events` is not JoobQ's events stream
      family = old.lchop?(OLD_PREFIX)
      type = redis.type(old)
      return true if type == "none" # gone
      if family && TRANSIENT.matches?(family)
        redis.del(old)
        return true
      end
      return false unless redis.type(new) == type

      case type
      when "list"
        # RIGHT to LEFT: the last old item goes first and ends up behind the others
        while redis.command(["LMOVE", old, new, "RIGHT", "LEFT"])
        end
      when "zset"
        redis.command(["ZUNIONSTORE", new, "2", new, old, "AGGREGATE", "MAX"])
      when "hash"
        merge_hash(redis, old, new, !family.nil? && COUNTERS.matches?(family))
        return true # the script deleted *old* with the merge
      end
      redis.del(old)
      true
    end

    # Folds hash *old* into *new* and deletes it in one script, so a run that is interrupted has either done all of it
    # or none, and a re-run cannot add a counter twice. With *counters*, an integer field is added to the new value;
    # a field that is not an integer on either side (or whose sum overflows) keeps the new value, and a field the new
    # hash lacks is copied. The script never raises.
    MERGE_HASH = <<-LUA
      local old = redis.call('HGETALL', KEYS[1])
      for i = 1, #old, 2 do
        local field, value = old[i], old[i + 1]
        local added = false
        if ARGV[1] == '1' and string.match(value, '^-?%d+$') then
          local current = redis.call('HGET', KEYS[2], field)
          if current and string.match(current, '^-?%d+$') then
            added = pcall(redis.call, 'HINCRBY', KEYS[2], field, value)
          end
        end
        if not added then redis.call('HSETNX', KEYS[2], field, value) end
      end
      redis.call('DEL', KEYS[1])
      return 1
    LUA

    def self.merge_hash(redis : Redis::PooledClient, old : String, new : String, counters : Bool) : Nil
      redis.eval(MERGE_HASH, [old, new], [counters ? "1" : "0"])
    end

    @@warned = Atomic(Bool).new(false)

    # Logs, once per process, that 0.6 keys are still in Redis: jobs waiting in them are invisible to this version.
    # True when it warned. `Queue#start` calls it. It SCANs the whole keyspace for `joobq:*` once per process (the
    # first queue to start pays for it).
    def self.warn_once(store : RedisStore, queues : Array(String)) : Bool
      return false if @@warned.swap(true)

      legacy = legacy_keys(store.redis, queues)
      return false if legacy.empty?

      Log.error &.emit("0.6 keys are still in Redis and are not read by this version; stop every JoobQ process, run JoobQ.migrate_keyspace!, then start them",
        count: legacy.size, example: legacy.first[0])
      true
    rescue ex
      Log.warn &.emit("Could not check for 0.6 keys", error: ex.message)
      false
    end

    # Specs only
    def self.reset_warning : Nil
      @@warned.set(false)
    end

    # Owners with a live heartbeat in either namespace, except this process.
    private def self.live_other_owners(store : RedisStore) : Set(String)
      (store.live_owners(OLD_OWNERS) + store.live_owners) - [store.owner_id]
    end
  end

  # Moves the keys a 0.6 JoobQ wrote into the `joobq:v1:` namespace. Run it once, with every other JoobQ process
  # stopped (it raises `KeyspaceMigrationError` while another process has a live heartbeat); it is safe to run again.
  # A key whose new name already exists is left where it is and listed in `Report#skipped`. *queues* names the queues
  # whose bare 0.6 lists move: the bare name could be another application's key, so no list is moved unless named.
  def self.migrate_keyspace!(queues : Array(String) = JoobQ.queues.keys, store : RedisStore = JoobQ.store.as(RedisStore)) : Keyspace::Report
    Keyspace.migrate!(store, queues)
  end

  # Whether any 0.6 key of *queues* (or any `joobq:` key without the version) is still there.
  def self.legacy_keyspace?(queues : Array(String) = JoobQ.queues.keys, store : RedisStore = JoobQ.store.as(RedisStore)) : Bool
    !Keyspace.legacy_keys(store.redis, queues).empty?
  end
end
