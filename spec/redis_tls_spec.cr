require "./spec_helper"

module JoobQ
  # Opt-in: needs a real TLS Redis. Set JOOBQ_SPEC_TLS_REDIS_URL (rediss://localhost:port) and JOOBQ_SPEC_TLS_CA_FILE
  # (the PEM of the private CA that signed its certificate, which names localhost and 127.0.0.1 and is not in the
  # system store). It is a different server from the one in REDIS_PORT and nothing on it
  # is flushed; each example removes only the key it wrote.
  #
  #   redis-server --port 0 --tls-port 6400 --tls-cert-file srv.pem --tls-key-file srv.key \
  #     --tls-ca-cert-file ca.pem --tls-auth-clients no --save "" --appendonly no
  describe "RedisStore over TLS" do
    url = ENV["JOOBQ_SPEC_TLS_REDIS_URL"]?
    ca_file = ENV["JOOBQ_SPEC_TLS_CA_FILE"]?
    stores = [] of RedisStore
    connect = ->(target : String, ca : String?, verify : Bool) do
      RedisStore.new(url: target, ca_file: ca, verify: verify, pool_size: 2).tap { |store| stores << store }
    end

    after_each do
      stores.each(&.close)
      stores.clear
    end

    it "connects to a rediss server whose certificate the CA file vouches for" do
      next pending!("set JOOBQ_SPEC_TLS_REDIS_URL and JOOBQ_SPEC_TLS_CA_FILE to a TLS Redis") unless url && ca_file

      store = connect.call(url, ca_file, true)

      store.redis.ping.should eq("PONG")
      store.redis.set("tls_spec:key", "value")
      store.redis.get("tls_spec:key").should eq("value")
    ensure
      if url && ca_file
        connect.call(url, ca_file, true).redis.del("tls_spec:key")
      end
    end

    it "refuses a certificate that was issued for another host name" do
      next pending!("set JOOBQ_SPEC_TLS_REDIS_URL and JOOBQ_SPEC_TLS_CA_FILE to a TLS Redis") unless url && ca_file

      # The spec certificate names localhost and 127.0.0.1. The same server reached as 127.0.0.2 presents a certificate
      # the CA signed, but not for that address: the chain is fine, the host name is not.
      other_host = url.sub(/\/\/[^:\/]+/, "//127.0.0.2")
      store = connect.call(other_host, ca_file, true)

      expect_raises(Exception, /certificate|verify|SSL/i) { store.redis.ping }
    end

    it "accepts the address the certificate names" do
      next pending!("set JOOBQ_SPEC_TLS_REDIS_URL and JOOBQ_SPEC_TLS_CA_FILE to a TLS Redis") unless url && ca_file

      by_ip = url.sub(/\/\/[^:\/]+/, "//127.0.0.1")
      connect.call(by_ip, ca_file, true).redis.ping.should eq("PONG")
    end

    it "refuses a server whose certificate no trusted CA signed" do
      next pending!("set JOOBQ_SPEC_TLS_REDIS_URL to a TLS Redis") unless url

      store = connect.call(url, nil, true)

      expect_raises(Exception) { store.redis.ping }
    end

    it "connects without checking the certificate only when verification is turned off" do
      next pending!("set JOOBQ_SPEC_TLS_REDIS_URL to a TLS Redis") unless url

      store = connect.call(url, nil, false)

      store.redis.ping.should eq("PONG")
    end
  end
end
