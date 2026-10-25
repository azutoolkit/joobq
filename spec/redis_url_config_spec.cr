require "./spec_helper"

module JoobQ
  # `redis.url` in the YAML file and REDIS_URL in the environment. A URL carries host, port, ACL user, password, TLS and
  # database together, so when one is given it is used as it is and REDIS_HOST, REDIS_PORT and REDIS_PASS do not
  # change it. Creating the store opens no connection.
  describe "Redis URL configuration" do
    load = ->(yaml : String) { YamlConfigLoader.load_from_string(yaml).store.as(RedisStore) }

    around_each do |example|
      saved = {"REDIS_URL" => ENV["REDIS_URL"]?, "REDIS_TLS_VERIFY" => ENV["REDIS_TLS_VERIFY"]?,
               "REDIS_CA_FILE" => ENV["REDIS_CA_FILE"]?, "REDIS_HOST" => ENV["REDIS_HOST"]?,
               "REDIS_PORT" => ENV["REDIS_PORT"]?, "REDIS_PASS" => ENV["REDIS_PASS"]?}
      saved.each_key { |name| ENV.delete(name) }
      begin
        example.run
      ensure
        saved.each { |name, value| value ? (ENV[name] = value) : ENV.delete(name) }
      end
    end

    it "uses the url from the YAML file" do
      store = load.call(<<-YAML)
        joobq:
          redis:
            url: "rediss://svc:pw@redis.example.com:6390/2"
            pool_size: 7
      YAML

      store.host.should eq("redis.example.com")
      store.port.should eq(6390)
      store.pool_size.should eq(7)
    end

    it "lets REDIS_URL override the YAML file" do
      ENV["REDIS_URL"] = "redis://env.example.com:6391"

      store = load.call(<<-YAML)
        joobq:
          redis:
            url: "redis://yaml.example.com:6390"
      YAML

      store.host.should eq("env.example.com")
      store.port.should eq(6391)
    end

    it "uses the url instead of the YAML host and port" do
      store = load.call(<<-YAML)
        joobq:
          redis:
            host: "ignored.example.com"
            port: 6000
            url: "redis://url.example.com:6390"
      YAML

      store.host.should eq("url.example.com")
      store.port.should eq(6390)
    end

    it "still reads host and port when there is no url" do
      store = load.call(<<-YAML)
        joobq:
          redis:
            host: "plain.example.com"
            port: 6000
      YAML

      store.host.should eq("plain.example.com")
      store.port.should eq(6000)
    end

    it "rejects an unusable url without repeating it" do
      error = expect_raises(ConfigLoadError) do
        load.call(<<-YAML)
          joobq:
            redis:
              url: "http://svc:hunter2@redis.example.com"
        YAML
      end

      error.message.to_s.should contain("scheme")
      error.message.to_s.should_not contain("hunter2")
    end
  end
end
