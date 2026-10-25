require "./spec_helper"

module JoobQ
  # Opt-in: needs a real TLS Redis. Set JOOBQ_SPEC_TLS_REDIS_URL (rediss://host:port) and JOOBQ_SPEC_TLS_CA_FILE (the
  # PEM of the CA that signed its certificate). It is a different server from the one in REDIS_PORT and nothing on it
  # is flushed; each example removes only the key it wrote.
  #
  #   redis-server --port 0 --tls-port 6400 --tls-cert-file srv.pem --tls-key-file srv.key \
  #     --tls-ca-cert-file ca.pem --tls-auth-clients no --save "" --appendonly no
  describe "RedisStore over TLS" do
    url = ENV["JOOBQ_SPEC_TLS_REDIS_URL"]?
    ca_file = ENV["JOOBQ_SPEC_TLS_CA_FILE"]?

    it "connects to a rediss server whose certificate the CA file vouches for" do
      next pending!("set JOOBQ_SPEC_TLS_REDIS_URL and JOOBQ_SPEC_TLS_CA_FILE to a TLS Redis") unless url && ca_file

      store = RedisStore.new(url: url, ca_file: ca_file, pool_size: 2)

      store.redis.ping.should eq("PONG")
      store.redis.set("tls_spec:key", "value")
      store.redis.get("tls_spec:key").should eq("value")
    ensure
      if url && ca_file
        RedisStore.new(url: url, ca_file: ca_file, pool_size: 1).redis.del("tls_spec:key")
      end
    end

    it "refuses a server whose certificate no trusted CA signed" do
      next pending!("set JOOBQ_SPEC_TLS_REDIS_URL to a TLS Redis") unless url

      store = RedisStore.new(url: url, pool_size: 2)

      expect_raises(Exception) { store.redis.ping }
    end

    it "connects without checking the certificate only when verification is turned off" do
      next pending!("set JOOBQ_SPEC_TLS_REDIS_URL to a TLS Redis") unless url

      store = RedisStore.new(url: url, verify: false, pool_size: 2)

      store.redis.ping.should eq("PONG")
    end
  end
end
