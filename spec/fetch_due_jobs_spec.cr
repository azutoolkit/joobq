require "./spec_helper"

module JoobQ
  describe RedisStore do
    it "#fetch_due_jobs removes only the jobs it returns" do
      JoobQ.reset
      store = JoobQ.store.as(RedisStore)
      60.times { |i| store.redis.zadd(RedisStore::DELAYED_SET, 1000 + i, %({"n":#{i}})) }

      first = store.fetch_due_jobs(Time.unix(10), limit: 50)
      first.size.should eq 50
      store.redis.zcard(RedisStore::DELAYED_SET).should eq 10

      rest = store.fetch_due_jobs(Time.unix(10), limit: 50)
      rest.size.should eq 10
      (first + rest).uniq.size.should eq 60
      store.redis.zcard(RedisStore::DELAYED_SET).should eq 0
    end

    it "#fetch_due_jobs leaves jobs that are not due yet, and can peek without removing" do
      JoobQ.reset
      store = JoobQ.store.as(RedisStore)
      store.redis.zadd(RedisStore::DELAYED_SET, 5_000, %({"n":1}))
      store.redis.zadd(RedisStore::DELAYED_SET, 99_999_999, %({"n":2}))

      store.fetch_due_jobs(Time.unix(10), remove: false).size.should eq 1
      store.redis.zcard(RedisStore::DELAYED_SET).should eq 2
      store.fetch_due_jobs(Time.unix(10)).size.should eq 1
      store.redis.zcard(RedisStore::DELAYED_SET).should eq 1
    end
  end
end
