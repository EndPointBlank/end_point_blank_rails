# frozen_string_literal: true

require "spec_helper"

RSpec.describe EndPointBlank::Management::Client, :management_api do
  let(:client) { management_client }
  let(:codes) { EndPointBlank::Management::ErrorCodes }

  def page(ids, next_cursor)
    { status: 200, body: { data: ids.map { |id| { id: id } }, next_cursor: next_cursor } }
  end

  describe "construction" do
    it "refuses a missing key, without a request" do
      expect { described_class.new(api_key: nil) }
        .to raise_error(EndPointBlank::ConfigurationError, /epb_mk_.*No key was given/)
    end

    it "refuses a key that is not a management key, and does not repeat it" do
      expect { described_class.new(api_key: "runtime-client-secret") }
        .to raise_error(EndPointBlank::ConfigurationError) { |error|
          expect(error.message).to include("epb_mk_")
          expect(error.message).not_to include("runtime-client-secret")
        }
      expect { described_class.new(api_key: "epb_mk_") }.to raise_error(EndPointBlank::ConfigurationError)
      expect { described_class.new(api_key: "epb_mk_a b") }.to raise_error(EndPointBlank::ConfigurationError)
    end

    it "refuses a key with a byte app_portal never mints, without a request and without repeating it" do
      stub_management_api
      ["epb_mk_a\x00b", "epb_mk_a\x01b", "epb_mk_a\x7Fb", "epb_mk_a\u00e9b", "epb_mk_a\rb", "epb_mk_a\nb",
       "epb_mk_a:b", "epb_mk_a+b/c=", "epb_mk_a\xFFb".b, "epb_mk_ab".encode("UTF-16LE")].each do |key|
        expect { described_class.new(api_key: key) }
          .to raise_error(EndPointBlank::ConfigurationError) { |error|
            expect(error.message).not_to include(key.b)
            expect(error.full_message).not_to include(key.b)
            expect(error.message).not_to include(key.inspect)
          }
      end
      expect(management_requests).to be_empty
    end

    it "accepts a key in app_portal's alphabet, and strips surrounding whitespace" do
      stub_management_api
      management_client(api_key: "  epb_mk_Ab9-_x\n").organization

      expect(management_requests.last.header("Authorization")).to eq("Bearer epb_mk_Ab9-_x")
    end

    it "defaults to https://app.endpointblank.com" do
      expect(described_class.new(api_key: ManagementApiStub::KEY).base_url).to eq("https://app.endpointblank.com")
    end

    it "refuses a base URL that is not plain http(s), without repeating it" do
      ["ftp://x.test", "not a url", "https://user:pw@x.test", "https://x.test/?a=1", ""].each do |url|
        expect { described_class.new(api_key: ManagementApiStub::KEY, base_url: url) }
          .to raise_error(EndPointBlank::ConfigurationError) { |error| expect(error.message).not_to include("pw@") }
      end
    end

    it "refuses unknown options and negative retries" do
      expect { management_client(retries: 1) }.to raise_error(ArgumentError, /retries/)
      expect { management_client(max_retries: -1) }.to raise_error(ArgumentError, /max_retries/)
    end

    it "strips any run of trailing slashes from the base URL, in linear time" do
      stub_management_api
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      mgmt = management_client(base_url: "https://portal.example.test/prefix#{"/" * 200_000}")
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      expect(mgmt.base_url).to eq("https://portal.example.test/prefix")
      expect(elapsed).to be < 1
      mgmt.organization
      expect(management_requests.last.path).to eq("/prefix/api/v1/organization")
      expect(EndPointBlank::Management::UrlPath.strip_trailing_slashes("///")).to eq("")
      expect(EndPointBlank::Management::UrlPath.strip_trailing_slashes("/a/b")).to eq("/a/b")
    end

    it "keeps the base URL's path prefix" do
      stub_management_api
      management_client(base_url: "https://portal.example.test/prefix/").organization

      expect(management_requests.last.path).to eq("/prefix/api/v1/organization")
    end
  end

  describe "configuration" do
    it "reads EndPointBlank::Management.configure, separate from the runtime configuration" do
      EndPointBlank::Management.configure do |m|
        m.api_key = ManagementApiStub::KEY
        m.base_url = "https://configured.example.test"
        m.max_retries = 0
      end
      stub_management_api(api_error(503, "intake_unavailable"))

      mgmt = EndPointBlank::Management.client(excon_options: { mock: true }, sleeper: sleeps_recorder)

      expect(mgmt.base_url).to eq("https://configured.example.test")
      expect { mgmt.organization }.to raise_error(EndPointBlank::Management::Error)
      expect(management_requests.size).to eq(1)
    end

    it "falls back to ENDPOINTBLANK_MANAGEMENT_KEY and ENDPOINTBLANK_MANAGEMENT_BASE_URL" do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with("ENDPOINTBLANK_MANAGEMENT_KEY", nil).and_return(ManagementApiStub::KEY)
      allow(ENV).to receive(:fetch).with("ENDPOINTBLANK_MANAGEMENT_BASE_URL", nil).and_return("https://env.example.test")

      expect(described_class.new.base_url).to eq("https://env.example.test")
    end

    it "is not the runtime configuration's base_url" do
      allow(EndPointBlank::Configuration.instance).to receive(:base_url).and_return("https://in.example.test")

      expect(described_class.new(api_key: ManagementApiStub::KEY).base_url).to eq("https://app.endpointblank.com")
    end
  end

  describe "headers" do
    it "authenticates with the management key as a Bearer token and never sends runtime credentials" do
      configuration = EndPointBlank::Configuration.instance
      allow(configuration).to receive(:client_id).and_return("runtime-client-id")
      allow(configuration).to receive(:client_secret).and_return("runtime-client-secret")
      stub_management_api(status: 201, body: { data: {} })

      client.api_packages.create(name: "Gold")

      request = management_requests.last
      expect(request.header("Authorization")).to eq("Bearer #{ManagementApiStub::KEY}")
      sent = request.headers.values.join(" ") + request.body.to_s
      expect(sent).not_to include("runtime-client-id")
      expect(sent).not_to include("runtime-client-secret")
      expect(sent).not_to include("Basic")
      expect(request.header("x-epb-sdk")).to be_nil
    end

    it "sends Accept, a User-Agent naming the SDK and its version, and Content-Type only with a body" do
      stub_management_api(status: 200, body: { data: {} }, headers: {})

      client.organization
      client.api_packages.create(name: "Gold")

      get, post = management_requests
      expect(get.header("Accept")).to eq("application/json")
      expect(get.header("User-Agent")).to eq("end_point_blank-ruby/#{EndPointBlank::VERSION} (management)")
      expect(get.header("Content-Type")).to be_nil
      expect(post.header("Content-Type")).to eq("application/json")
    end
  end

  describe "pagination" do
    it "returns one page with its next_cursor" do
      stub_management_api(page(%w[a b], "cursor-1"))

      result = client.applications.list(limit: 2)

      expect(result).to be_a(EndPointBlank::Management::Page)
      expect(result.map { |item| item["id"] }).to eq(%w[a b])
      expect(result.next_cursor).to eq("cursor-1")
      expect(result.next_page?).to be(true)
      expect(management_requests.last.query).to eq("limit" => "2")
    end

    it "walks every page with each, passing next_cursor as after" do
      stub_management_api(page(%w[a b], "c1"), page(%w[c d], "c2"), page(%w[e], nil))

      ids = client.clients.each(limit: 2).map { |item| item["id"] }

      expect(ids).to eq(%w[a b c d e])
      expected = [{ "limit" => "2" }, { "limit" => "2", "after" => "c1" }, { "limit" => "2", "after" => "c2" }]
      expect(management_requests.map(&:query)).to eq(expected)
    end

    it "yields to a block, and fetches lazily" do
      stub_management_api(page(%w[a b], "c1"), page(%w[c], nil))

      enumerator = client.package_assignments.each("client-1")
      expect(management_requests).to be_empty
      expect(enumerator.first).to eq("id" => "a")
      expect(management_requests.size).to eq(1)

      seen = []
      Excon.stubs.clear
      management_requests.clear
      stub_management_api(page(%w[a b], "c1"), page(%w[c], nil))
      expect(client.package_assignments.each("client-1") { |item| seen << item["id"] }).to be_nil
      expect(seen).to eq(%w[a b c])
      expect(management_requests.map(&:path).uniq).to eq(["/api/v1/clients/client-1/packages"])
    end

    it "keeps filters on every page" do
      stub_management_api(page(%w[a], "c1"), page(%w[b], nil))

      client.credentials.each(application_environment_id: "ae-1").to_a

      expected = [{ "application_environment_id" => "ae-1" },
                  { "application_environment_id" => "ae-1", "after" => "c1" }]
      expect(management_requests.map(&:query)).to eq(expected)
    end

    it "refuses a limit outside 1..100 without a request" do
      stub_management_api
      [0, 101, "10", 2.5].each do |limit|
        expect { client.environments.list(limit: limit) }.to raise_error(ArgumentError, /limit/)
        expect { client.environments.each(limit: limit) }.to raise_error(ArgumentError, /limit/)
      end
      expect(management_requests).to be_empty
    end
  end

  describe "idempotency" do
    it "generates a UUID v4 Idempotency-Key per POST" do
      stub_management_api(status: 201, body: { data: {} })

      client.environments.create(name: "a", domain: "a.test")
      client.environments.create(name: "b", domain: "b.test")

      first, second = management_requests.map { |request| request.header("Idempotency-Key") }
      expect(first).to match(/\A\h{8}-\h{4}-4\h{3}-[89ab]\h{3}-\h{12}\z/)
      expect(second).not_to eq(first)
    end

    it "reuses the same key when it retries a POST" do
      stub_management_api(api_error(503, "audit_unavailable"), api_error(500, "internal_server_error"),
                          status: 201, body: { data: { id: "new" } })

      expect(client.api_packages.create(name: "Gold")).to eq("id" => "new")

      keys = management_requests.map { |request| request.header("Idempotency-Key") }
      expect(keys.size).to eq(3)
      expect(keys.uniq.size).to eq(1)
    end

    it "sends the caller's key, and reuses it on retry" do
      stub_management_api(api_error(429, "rate_limited", headers: { "Retry-After" => "1" }),
                          status: 201, body: { data: {} })

      client.clients.invite(name: "Acme", idempotency_key: "order-42-invite")

      expect(management_requests.map { |request| request.header("Idempotency-Key") })
        .to eq(%w[order-42-invite order-42-invite])
    end

    it "retries idempotency_request_in_progress with the same key" do
      stub_management_api(api_error(409, "idempotency_request_in_progress"), status: 201, body: { data: {} })

      client.grants.create("c", target_application_id: "a", environment_id: "e")

      expect(management_requests.size).to eq(2)
      expect(management_requests.map { |request| request.header("Idempotency-Key") }.uniq.size).to eq(1)
      expect(sleeps).to eq([1])
    end

    it "does not retry idempotency_replay_unavailable, and says to read the resource" do
      stub_management_api(api_error(409, "idempotency_replay_unavailable",
                                    headers: { "Location" => "/api/v1/credentials/cred-1" }))

      expect { client.credentials.create(application_environment_id: "ae-1", idempotency_key: "k1") }
        .to raise_error(EndPointBlank::Management::Error) { |error|
          expect(error.code).to eq(codes::IDEMPOTENCY_REPLAY_UNAVAILABLE)
          expect(error.status).to eq(409)
          expect(error.location).to eq("/api/v1/credentials/cred-1")
          expect(error.message).to include("Read or list the resource", "/api/v1/credentials/cred-1")
        }
      expect(management_requests.size).to eq(1)
    end

    it "refuses an Idempotency-Key on anything but a POST, and an empty or overlong one" do
      transport = client.instance_variable_get(:@transport)
      expect { transport.request("GET", "/organization", idempotency_key: "k") }.to raise_error(ArgumentError)
      expect { client.api_packages.create(name: "x", idempotency_key: " ") }.to raise_error(ArgumentError)
      expect { client.api_packages.create(name: "x", idempotency_key: "k" * 256) }.to raise_error(ArgumentError)
    end
  end

  describe "retries" do
    it "honours Retry-After on 429, then succeeds" do
      stub_management_api(api_error(429, "rate_limited", headers: { "Retry-After" => "7" }),
                          status: 200, body: { data: { id: "org" } })

      expect(client.organization).to eq("id" => "org")
      expect(sleeps).to eq([7])
    end

    it "waits 1 second on a 429 without Retry-After" do
      stub_management_api({ status: 429, body: "Too Many Requests" }, status: 200, body: { data: {} })

      client.organization

      expect(sleeps).to eq([1])
    end

    it "retries a 429 on PATCH too: nothing was done" do
      stub_management_api(api_error(429, "rate_limited", headers: { "retry-after" => "2" }),
                          status: 200, body: { data: {} })

      client.applications.update("app", name: "x")

      expect(management_requests.size).to eq(2)
    end

    it "stops after max_retries and raises the last error with its retry_after" do
      stub_management_api(api_error(429, "rate_limited", headers: { "Retry-After" => "1" }))

      expect { client.organization }.to raise_error(EndPointBlank::Management::Error) { |error|
        expect(error.code).to eq("rate_limited")
        expect(error.status).to eq(429)
        expect(error.retry_after).to eq(1)
      }
      expect(management_requests.size).to eq(3)
      expect(sleeps).to eq([1, 1])
    end

    it "can be turned off" do
      stub_management_api(api_error(429, "rate_limited", headers: { "Retry-After" => "1" }))

      expect { management_client(max_retries: 0).organization }.to raise_error(EndPointBlank::Management::Error)
      expect(management_requests.size).to eq(1)
      expect(sleeps).to be_empty
    end

    it "does not wait out a Retry-After longer than max_retry_wait" do
      stub_management_api(api_error(429, "rate_limited", headers: { "Retry-After" => "120" }))

      expect { management_client(max_retry_wait: 60).organization }.to raise_error(EndPointBlank::Management::Error)
      expect(management_requests.size).to eq(1)
    end

    it "retries 5xx with backoff for GET, DELETE and POST" do
      stub_management_api(api_error(503, "intake_unavailable"), status: 200, body: { data: {} })
      client.credentials.delete("cred-1")
      expect(sleeps).to eq([0.5])

      Excon.stubs.clear
      management_requests.clear
      stub_management_api({ status: 502, body: "<html>Bad gateway</html>" }, { status: 502, body: "" },
                          status: 200, body: { data: {} })
      client.environments.get("env-1")
      expect(management_requests.size).to eq(3)
      expect(sleeps).to eq([0.5, 0.5, 1.0])
    end

    it "never retries a 5xx on PATCH" do
      stub_management_api(api_error(503, "audit_unavailable"), status: 200, body: { data: {} })

      expect { client.environments.update("env-1", name: "x") }
        .to raise_error(EndPointBlank::Management::Error) { |error| expect(error.code).to eq("audit_unavailable") }
      expect(management_requests.size).to eq(1)
    end

    it "retries a request that never got an answer, but not a PATCH" do
      socket_error = Excon::Error::Socket.new(StandardError.new("connection refused"))
      stub_management_api({ raise: socket_error }, status: 200, body: { data: { id: "org" } })
      expect(client.organization).to eq("id" => "org")

      Excon.stubs.clear
      management_requests.clear
      stub_management_api(raise: socket_error)
      expect { client.applications.update("a", name: "x") }
        .to raise_error(EndPointBlank::Management::Error) { |error|
          expect(error.code).to eq(codes::CONNECTION_ERROR)
          expect(error.status).to be_nil
        }
      expect(management_requests.size).to eq(1)
    end

    it "does not retry a 4xx refusal" do
      stub_management_api(api_error(422, "validation_failed"))

      expect { client.api_packages.create(name: "") }.to raise_error(EndPointBlank::Management::Error)
      expect(management_requests.size).to eq(1)
    end
  end

  describe "errors" do
    def raised(answer)
      stub_management_api(answer)
      yield
      raise "expected an error"
    rescue EndPointBlank::Management::Error => e
      e
    end

    it "maps 404 not_found" do
      error = raised(api_error(404, "not_found", "Not found.")) { client.api_packages.get("missing") }

      expect(error).to be_a(EndPointBlank::Error)
      expect([error.code, error.status, error.message]).to eq(["not_found", 404, "Not found."])
      expect(error.code?(:not_found)).to be(true)
      expect(error.http_method).to eq("GET")
      expect(error.path).to eq("/api_packages/missing")
    end

    it "maps 422 validation_failed with its details" do
      details = { "name" => ["can't be blank"] }
      error = raised(api_error(422, "validation_failed", "The request has invalid fields.", details: details)) do
        client.api_packages.create(name: "")
      end

      expect(error.code).to eq(codes::VALIDATION_FAILED)
      expect(error.status).to eq(422)
      expect(error.details).to eq(details)
    end

    it "maps 402 plan_limit" do
      error = raised(api_error(402, "plan_limit", "Your plan's limit for this resource is reached.")) do
        client.clients.invite(name: "One too many")
      end

      expect([error.code, error.status]).to eq([codes::PLAN_LIMIT, 402])
    end

    it "keeps a code this SDK does not know" do
      error = raised(api_error(422, "brand_new_refusal", "Something new.")) { client.clients.delete("c") }

      expect(error.code).to eq("brand_new_refusal")
      expect(codes.known?(error.code)).to be(false)
      expect(error.message).to eq("Something new.")
    end

    it "makes sense of an error body that is not JSON" do
      error = raised(status: 403, body: "<html>Forbidden by proxy</html>") { client.organization }

      expect(error.code).to eq(codes::HTTP_ERROR)
      expect(error.status).to eq(403)
      expect(error.message).to include("HTTP 403", "Forbidden by proxy")
    end

    it "makes sense of a success body that is not JSON" do
      error = raised(status: 200, body: "<html>login</html>") { client.organization }

      expect([error.code, error.status]).to eq([codes::INVALID_RESPONSE, 200])
    end

    it "reads X-Request-Id" do
      error = raised(api_error(404, "not_found", headers: { "x-request-id" => "req-1" })) { client.organization }

      expect(error.request_id).to eq("req-1")
    end
  end

  describe "the key is never shown" do
    it "in inspect or to_s of the client, its configuration or its views" do
      EndPointBlank::Management.configure { |m| m.api_key = ManagementApiStub::KEY }

      [client, client.for_managed_client("c"), client.api_packages, EndPointBlank::Management.configuration,
       client.instance_variable_get(:@transport)].each do |object|
        expect(object.inspect).not_to include(ManagementApiStub::KEY)
        expect(object.to_s).not_to include(ManagementApiStub::KEY)
      end
      expect(client.inspect).to include("[REDACTED]")
    end

    it "in a connection error's message" do
      stub_management_api(raise: Excon::Error::Socket.new(StandardError.new("bad #{ManagementApiStub::KEY}")))

      expect { management_client(max_retries: 0).organization }
        .to raise_error(EndPointBlank::Management::Error) { |error|
          expect(error.message).not_to include(ManagementApiStub::KEY)
          expect(error.inspect).not_to include(ManagementApiStub::KEY)
        }
    end

    it "nor a credential secret, in the retry log" do
      logger = instance_double(Logger, debug: nil)
      allow(EndPointBlank).to receive(:logger).and_return(logger)
      stub_management_api(api_error(503, "intake_unavailable"),
                          status: 201, body: { data: { client_secret: "s3cret" } })

      client.credentials.create(application_environment_id: "ae-1")

      expect(logger).to have_received(:debug).once do |line|
        expect(line).to include("POST /credentials", "503", "intake_unavailable")
        expect(line).not_to include(ManagementApiStub::KEY)
        expect(line).not_to include("s3cret")
      end
    end
  end

  describe EndPointBlank::Management::ErrorCodes do
    it "lists every code the API documents, with its status" do
      expect(described_class::ALL.size).to eq(45)
      expect(described_class::STATUSES).to include("plan_limit" => 402, "rate_limited" => 429,
                                                   "not_found" => 404, "idempotency_replay_unavailable" => 409,
                                                   "return_to_not_registered" => 422)
      expect(described_class::ALL).not_to include("unsupported_media_type", "request_entity_too_large")
    end
  end
end
