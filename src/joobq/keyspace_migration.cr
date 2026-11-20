module JoobQ
  # Another process is live, so its keys are not moved from under it.
  class KeyspaceMigrationError < Exception
  end

  # Moves a 0.6 keyspace into `Keys::PREFIX`. 0.6 kept the waiting jobs of a queue under the bare queue name and its
  # other keys under `joobq:` with no version.
  module Keyspace
    record Report, renamed : Int32, skipped : Array(String)

    OLD_PREFIX = "joobq:"
    OLD_OWNERS = "joobq:processing-owners"

    # The old name of every key that moves unchanged apart from the prefix (a family is the text after `joobq:`).
    private FAMILIES = /\A(processing|processing-owners|delayed_jobs|dead_letter|dead_letter:counts|error_counts|recent_errors|error_index|workers|events|events:trim_lock|failed_jobs|stats:.+|retry_lock:.+|worker:.+|delivery-bridge:.+)\z/
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

      renamed = 0
      skipped = [] of String
      legacy_keys(store.redis, queues).each do |(old, new)|
        if store.redis.renamenx(old, new) == 1
          renamed += 1
        else
          skipped << old
          Log.warn &.emit("Keyspace migration left a key: the new name already exists", old: old, new: new)
        end
      rescue ex : Redis::Error
        # the key went away (another migration) between the scan and the rename
        raise ex unless ex.message.try(&.includes?("no such key"))
      end
      Log.info &.emit("Keyspace migrated to #{Keys::PREFIX}", renamed: renamed, skipped: skipped.size)
      Report.new(renamed, skipped)
    end

    @@warned = Atomic(Bool).new(false)

    # Logs, once per process, that 0.6 keys are still in Redis: jobs waiting in them are invisible to this version.
    # True when it warned. `Queue#start` calls it.
    def self.warn_once(store : RedisStore, queues : Array(String)) : Bool
      return false if @@warned.swap(true)

      legacy = legacy_keys(store.redis, queues)
      return false if legacy.empty?

      Log.error &.emit("0.6 keys are still in Redis and are not read by this version; stop every JoobQ process and run JoobQ.migrate_keyspace!",
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
