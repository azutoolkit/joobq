require "./spec_helper"
require "file_utils"
require "openssl"

module JoobQ
  # Always-on check that a rediss connection verifies the server's host name, not only its chain: a throwaway CA and a
  # certificate for "localhost" are generated with the openssl command-line tool (the examples are pending without it,
  # or when it cannot make the certificates) and served by a tiny in-process TLS endpoint that answers PING. Reached
  # as 127.0.0.1, the certificate is valid for a different name and the connection must be refused.
  describe "RedisStore TLS host name" do
    openssl = Process.find_executable("openssl")
    dir = File.join(Dir.tempdir, "joobq_tls_#{Process.pid}_#{Random.new.hex(4)}")
    server = nil.as(TCPServer?)
    port = 0
    ca_file = ""
    ready = false
    stores = [] of RedisStore

    run = ->(args : Array(String)) do
      status = Process.run(openssl.not_nil!, args, chdir: dir, output: Process::Redirect::Close, error: Process::Redirect::Close)
      raise "openssl #{args.first} failed" unless status.success?
    end

    before_all do
      next unless openssl

      begin
        Dir.mkdir_p(dir)
        run.call(%w[req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout ca.key -out ca.pem -days 2 -subj /CN=joobq-spec-ca])
        run.call(%w[req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout srv.key -out srv.csr -subj /CN=localhost])
        File.write(File.join(dir, "ext.cnf"), "subjectAltName=DNS:localhost\n")
        run.call(%w[x509 -req -in srv.csr -CA ca.pem -CAkey ca.key -CAcreateserial -out srv.pem -days 2 -extfile ext.cnf])

        context = OpenSSL::SSL::Context::Server.new
        context.certificate_chain = File.join(dir, "srv.pem")
        context.private_key = File.join(dir, "srv.key")
        tcp = TCPServer.new("127.0.0.1", 0)
        server = tcp
        port = tcp.local_address.port
        ca_file = File.join(dir, "ca.pem")

        spawn do
          while client = tcp.accept?
            spawn do
              begin
                OpenSSL::SSL::Socket::Server.open(client, context) do |ssl|
                  buffer = Bytes.new(256)
                  while ssl.read(buffer) > 0
                    ssl.print("+PONG\r\n")
                    ssl.flush
                  end
                end
              rescue
                # a client that refuses the certificate aborts the handshake; that is the point of the example
              ensure
                client.close rescue nil
              end
            end
          end
        end
        ready = true
      rescue
        # this openssl cannot make the certificates (another flavour or version): the examples are pending
      end
    end

    after_each do
      stores.each(&.close)
      stores.clear
    end

    after_all do
      server.try(&.close)
      FileUtils.rm_rf(dir)
    end

    connect = ->(host : String, verify : Bool) do
      RedisStore.new(url: "rediss://#{host}:#{port}", ca_file: ca_file, verify: verify, pool_size: 1).tap { |store| stores << store }
    end

    it "accepts the name the certificate was issued for" do
      next pending!("needs an openssl command-line tool that can make the test certificates") unless ready

      connect.call("localhost", true).redis.ping.should eq("PONG")
    end

    it "refuses the same certificate when the server is reached under another name" do
      next pending!("needs an openssl command-line tool that can make the test certificates") unless ready

      store = connect.call("127.0.0.1", true)

      expect_raises(Exception, /certificate|verif|SSL/i) { store.redis.ping }
    end

    it "connects under another name only when verification is turned off" do
      next pending!("needs an openssl command-line tool that can make the test certificates") unless ready

      connect.call("127.0.0.1", false).redis.ping.should eq("PONG")
    end
  end
end
