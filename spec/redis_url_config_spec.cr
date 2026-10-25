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

    it "ignores REDIS_HOST, REDIS_PORT and REDIS_PASS when a url is given" do
      ENV["REDIS_HOST"] = "other.example.com"
      ENV["REDIS_PORT"] = "6000"
      ENV["REDIS_PASS"] = "other-secret"

      store = load.call(<<-YAML)
        joobq:
          redis:
            url: "rediss://url.example.com:6390"
      YAML

      store.host.should eq("url.example.com")
      store.port.should eq(6390)
    end

    it "reads TLS verification and the CA file from the environment, then the YAML file" do
      fixture = File.expand_path("fixtures/tls/ca.pem", __DIR__)
      ENV["REDIS_CA_FILE"] = fixture
      ENV["REDIS_TLS_VERIFY"] = "off"

      from_env = load.call(<<-YAML).endpoint.not_nil!
        joobq:
          redis:
            url: "rediss://u.example.com"
            ca_file: "/etc/ssl/unreadable-yaml-ca.pem"
            tls_verify: true
      YAML
      from_env.verify?.should be_false
      from_env.ca_file.should eq(fixture)

      ENV.delete("REDIS_CA_FILE")
      ENV.delete("REDIS_TLS_VERIFY")
      from_yaml = load.call(<<-YAML).endpoint.not_nil!
        joobq:
          redis:
            url: "rediss://u.example.com"
            ca_file: "#{fixture}"
            tls_verify: false
      YAML
      from_yaml.verify?.should be_false
      from_yaml.ca_file.should eq(fixture)
    end

    it "verifies by default" do
      load.call(<<-YAML).endpoint.not_nil!.verify?.should be_true
        joobq:
          redis:
            url: "rediss://u.example.com"
      YAML
    end

    it "refuses values it cannot read instead of guessing" do
      ENV["REDIS_TLS_VERIFY"] = "fasle"
      expect_raises(ConfigLoadError, /REDIS_TLS_VERIFY/) do
        load.call("joobq:\n  redis:\n    url: \"rediss://u.example.com\"\n")
      end

      ENV.delete("REDIS_TLS_VERIFY")
      expect_raises(ConfigLoadError, /tls_verify/) do
        load.call("joobq:\n  redis:\n    url: \"rediss://u.example.com\"\n    tls_verify: \"false\"\n")
      end
      expect_raises(ConfigLoadError, /redis.url/) do
        load.call("joobq:\n  redis:\n    url: 6379\n")
      end
    end

    describe "the default store" do
      it "is built from REDIS_URL when no YAML file says otherwise" do
        ENV["REDIS_URL"] = "rediss://default.example.com:6395"
        ENV["REDIS_HOST"] = "must-not-be-used.example.com"

        store = Configure.new.store.as(RedisStore)

        store.host.should eq("default.example.com")
        store.port.should eq(6395)
        store.endpoint.not_nil!.tls?.should be_true
      end

      it "is built from REDIS_HOST, REDIS_PORT and REDIS_PASS without a URL" do
        ENV["REDIS_HOST"] = "legacy.example.com"
        ENV["REDIS_PORT"] = "6396"

        store = RedisStore.from_env

        store.host.should eq("legacy.example.com")
        store.port.should eq(6396)
        store.endpoint.should be_nil
      end

      it "refuses an unusable REDIS_URL instead of falling back to a plain connection" do
        ENV["REDIS_URL"] = "http://svc:hunter2@redis.example.com"

        error = expect_raises(RedisEndpoint::Invalid) { RedisStore.from_env }

        error.message.to_s.should_not contain("hunter2")
      end
    end

    describe "merged sources" do
      write = ->(yaml : String) do
        path = File.tempname("joobq_redis_url", ".yml")
        File.write(path, yaml)
        path
      end

      it "keeps the url of the source that set it, whichever order the sources come in" do
        with_url = write.call("joobq:\n  redis:\n    url: \"rediss://merged.example.com:6397\"\n")
        without = write.call("joobq:\n  settings:\n    retries: 4\n")
        begin
          [[with_url, without], [without, with_url]].each do |sources|
            store = YamlConfigLoader.load_from_sources(sources).store.as(RedisStore)

            store.host.should eq("merged.example.com")
            store.endpoint.not_nil!.tls?.should be_true
          end
        ensure
          File.delete(with_url)
          File.delete(without)
        end
      end

      it "lets a later source override an earlier url" do
        first = write.call("joobq:\n  redis:\n    url: \"rediss://first.example.com\"\n")
        second = write.call("joobq:\n  redis:\n    url: \"rediss://second.example.com\"\n")
        begin
          YamlConfigLoader.load_from_sources([first, second]).store.as(RedisStore).host.should eq("second.example.com")
        ensure
          File.delete(first)
          File.delete(second)
        end
      end
    end
  end
end
