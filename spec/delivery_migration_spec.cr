require "./spec_helper"

describe "durable migration and recovery" do
  it "imports without deleting originals, resumes, and gates claims until verification" do
    store = JoobQ::RedisStore.instance
    namespace = "migration-#{UUID.random}"
    queue = "migration-queue-#{UUID.random}"
    ledger = JoobQ::Delivery::Ledger.new(store.redis, namespace, queue)
    first = ExampleJob.new(1)
    first.queue = queue
    second = ExampleJob.new(2)
    second.queue = queue
    store.redis.rpush(queue, first.to_json)
    store.redis.rpush("joobq:processing:#{queue}", second.to_json)
    migrator = JoobQ::Delivery::Migration.new(ledger, store.redis, queue, "operator")
    expect_raises(ArgumentError) { migrator.run }
    report = migrator.run(quiescent: true)
    report.logical_records.should eq(2)
    ledger.claim("worker").should be_nil
    migrator.run(quiescent: true).digest.should eq(report.digest)
    store.redis.llen(queue).should eq(1)
    store.redis.llen("joobq:processing:#{queue}").should eq(1)
    migrator.activate(report)
    ledger.claim("worker").should_not be_nil
  end

  it "restores a verified namespace onto an independent Redis and rejects corruption" do
    primary = JoobQ::RedisStore.instance
    secondary = JoobQ::RedisStore.new(host: ENV.fetch("REDIS_HOST"), port: ENV.fetch("JOOBQ_SPEC_SECOND_REDIS_PORT").to_i)
    namespace = "backup-#{UUID.random}"
    ledger = JoobQ::Delivery::Ledger.new(primary.redis, namespace, "work")
    ledger.admit("request", %({"n":9223372036854775807}))
    backup = JoobQ::Delivery::Backup.new(primary.redis, namespace)
    image = IO::Memory.new
    backup.export(image, quiescent: true)
    restore = JoobQ::Delivery::Backup.new(secondary.redis, namespace)
    count = restore.restore(IO::Memory.new(image.to_s))
    count.should be > 0
    restore.restore(IO::Memory.new(image.to_s)).should eq(count)
    restored = JoobQ::Delivery::Ledger.new(secondary.redis, namespace, "work")
    restored.resolve("request").not_nil!.payload.should eq(%({"n":9223372036854775807}))
    restored.claim("restored-worker").should_not be_nil
    expect_raises(ArgumentError) { restore.restore(IO::Memory.new(image.to_s)) }
    json = JSON.parse(image.to_s)
    json["entries"][0].as_h["digest"] = JSON::Any.new("invalid")
    expect_raises(ArgumentError, /digest/) { restore.restore(IO::Memory.new(json.to_json)) }
  ensure
    secondary.try(&.close)
  end

  it "quarantines poisoned canonical records without starving healthy work" do
    redis = JoobQ::RedisStore.instance.redis
    ledger = JoobQ::Delivery::Ledger.new(redis, "poison", UUID.random.to_s)
    receipt = ledger.admit("broken", "payload")
    redis.hset(ledger.records_key, receipt.id, "invalid")
    ledger.admit("healthy", "okay")
    ledger.repair
    redis.hget(ledger.quarantine_key, receipt.id).should eq("invalid")
    ledger.claim("worker").not_nil!.payload.should eq("okay")
    redis.hget(ledger.records_key, receipt.id).should eq("invalid")
  end
end

describe JoobQ::Delivery::Backup do
  it "rejects expiring keys instead of silently restoring them permanently" do
    store = JoobQ::RedisStore.instance
    namespace = "backup-ttl-#{UUID.random}"
    store.redis.set("joobq:v1:#{namespace}:unsupported", "value", px: 60_000)
    image = IO::Memory.new
    expect_raises(ArgumentError, /persistent keys/) do
      JoobQ::Delivery::Backup.new(store.redis, namespace).export(image, quiescent: true)
    end
    image.empty?.should be_true
  end
end
