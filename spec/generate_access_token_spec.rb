# frozen_string_literal: true

require "spec_helper"
require "end_point_blank/commands/generate_access_token"

RSpec.describe EndPointBlank::Commands::GenerateAccessToken do
  let(:logger) { double("logger", error: nil, warn: nil, info: nil) }
  let(:configuration) { EndPointBlank::Configuration.instance }

  before do
    allow(EndPointBlank).to receive(:logger).and_return(logger)
    configuration.client_id = "id"
    configuration.client_secret = "secret"
  end

  it "passes explicit connect and read timeouts to Excon" do
    allow(Excon).to receive(:post).and_return(double(status: 200, body: "{}"))

    described_class.token("host.example.com")

    expect(Excon).to have_received(:post).with(
      configuration.access_token_url,
      hash_including(connect_timeout: EndPointBlank::Commands::Http::CONNECT_TIMEOUT,
                      read_timeout: EndPointBlank::Commands::Http::READ_TIMEOUT)
    )
  end

  it "does not raise when Excon times out" do
    allow(Excon).to receive(:post).and_raise(Excon::Error::Timeout.new("timed out"))

    result = nil
    expect { result = described_class.token("host.example.com") }.not_to raise_error
    expect(result).to be_nil
  end

  it "logs the response status without the response body, which may carry a live bearer token" do
    allow(Excon).to receive(:post).and_return(
      double(status: 201, body: '{"token":"tok-secret-value","expired_at":"2026-08-13T18:00:00Z","base_url":"https://example.com"}')
    )

    described_class.token("https://example.com")

    expect(logger).to have_received(:info) do |message|
      expect(message).to include("201")
      expect(message).not_to include("tok-secret-value")
    end
  end

  # sc-189. intake's access-token endpoint answers 201 on success, 400 for a
  # bad request (invalid token_ttl, missing base_url), 401 for a rejected
  # credential, 422 for "missing target/source application" or a failed mint,
  # and 5xx for a genuine fault. Those statuses carry different remedies, and
  # `token` above throws all of them away: it hands back the parsed body no
  # matter what came back, so a caller cannot tell "re-issue the credential"
  # from "try again in a minute".
  describe ".token_result" do
    def stub_response(status, body)
      allow(Excon).to receive(:post).and_return(double("response", status: status, body: body))
    end

    it "reports a 201 as a success carrying the parsed payload" do
      stub_response(201, JSON.generate(token: "tok", expired_at: "2099-01-01T00:00:00Z",
                                       base_url: "https://example.com"))

      result = described_class.token_result("https://example.com")

      expect(result).to be_success
      expect(result).not_to be_credential_rejected
      expect(result.status).to eq(201)
      expect(result.payload).to include(token: "tok", base_url: "https://example.com")
    end

    it "treats any 2xx as a success, not only 201" do
      stub_response(200, JSON.generate(token: "tok", base_url: "https://example.com"))

      expect(described_class.token_result("https://example.com")).to be_success
    end

    # The whole point of the story: a 401 is permanent until the credential
    # itself changes, so it must carry its own name and its own status.
    it "reports a 401 as a rejected credential" do
      stub_response(401, JSON.generate(error: "invalid credentials"))

      result = described_class.token_result("https://example.com")

      expect(result).to be_credential_rejected
      expect(result).not_to be_success
      expect(result.status).to eq(401)
      expect(result.payload).to eq(error: "invalid credentials")
    end

    # intake answers 422 for "Missing target application" / "Missing source
    # application" / "Failed to create access token", and 400 for an invalid
    # token_ttl or a missing base_url. Retrying those is exactly as futile as
    # retrying a 401 -- the remedy is just different (register the
    # environment, or fix the request) -- so they must not land in a bucket a
    # caller reads as transient.
    it "reports a 422 as a rejected request, permanent but not a credential problem" do
      stub_response(422, JSON.generate(error: "Missing target application"))

      result = described_class.token_result("https://example.com")

      expect(result).to be_request_rejected
      expect(result).not_to be_credential_rejected
      expect(result.status).to eq(422)
    end

    it "reports a 400 as a rejected request too" do
      stub_response(400, JSON.generate(error: "Missing required parameter: base_url"))

      result = described_class.token_result("https://example.com")

      expect(result).to be_request_rejected
    end

    it "reports a 5xx as a server error" do
      stub_response(503, JSON.generate(error: "unavailable"))

      result = described_class.token_result("https://example.com")

      expect(result).to be_server_error
      expect(result.status).to eq(503)
    end

    it "reports a transport failure as a transport error, with no status to report" do
      allow(Excon).to receive(:post).and_raise(Excon::Error::Timeout.new("timed out"))

      result = described_class.token_result("https://example.com")

      expect(result).to be_transport_error
      expect(result.status).to be_nil
      expect(result.payload).to be_nil
    end

    # The one case where the body decides anything: a success status we cannot
    # read carries no token, so it is a broken server -- and a broken server
    # is worth another try. It is NOT a transport error: a status was
    # obtained, which is what that outcome is reserved for.
    it "reports a 2xx whose body will not parse as a server error, keeping the status" do
      stub_response(200, "not json at all")

      result = described_class.token_result("https://example.com")

      expect(result).to be_server_error
      expect(result).not_to be_transport_error
      expect(result.status).to eq(200)
      expect(result.payload).to be_nil
    end

    # The regression this guards against is parse-first classification. It is
    # not hypothetical: the SDK reaches intake through Caddy, and any proxy,
    # WAF or ALB in front of the app can answer 401 with an HTML error page
    # intake never generated -- so the credential really is rejected and the
    # body really is unparseable at the same time. Calling that a transport
    # error would invite a retry loop on a credential that is never coming
    # back.
    it "still reports a 401 with an HTML error page from a proxy as a rejected credential" do
      stub_response(401, "<html><body><h1>401 Unauthorized</h1></body></html>")

      result = described_class.token_result("https://example.com")

      expect(result).to be_credential_rejected
      expect(result).not_to be_transport_error
      expect(result.status).to eq(401)
      expect(result.payload).to be_nil
    end

    it "still reports a 422 with an unreadable body as a rejected request" do
      stub_response(422, "<html>no</html>")

      result = described_class.token_result("https://example.com")

      expect(result).to be_request_rejected
    end

    it "still reports a 503 with an unreadable body as a server error" do
      stub_response(503, "<html>bad gateway</html>")

      result = described_class.token_result("https://example.com")

      expect(result).to be_server_error
      expect(result.status).to eq(503)
    end

    # :transport_error is reserved for "no usable HTTP status was obtained",
    # so it never carries one. A body problem is never a transport problem.
    it "never reports a transport error for a response that had a status" do
      [200, 401, 422, 500].each do |status|
        stub_response(status, "not json")

        expect(described_class.token_result("https://example.com")).not_to be_transport_error
      end
    end

    # The invariant stated the other way round: no usable status means
    # transport error, whether the status was unobtainable or simply absent.
    it "reports a response whose status is not a number as a transport error" do
      stub_response(nil, JSON.generate(token: "tok", base_url: "https://example.com"))

      result = described_class.token_result("https://example.com")

      expect(result).to be_transport_error
      expect(result.status).to be_nil
    end

    it "reports a response object that cannot even yield a status as a transport error" do
      broken = double("response")
      allow(broken).to receive(:status).and_raise(NoMethodError.new("no status"))
      allow(Excon).to receive(:post).and_return(broken)

      result = described_class.token_result("https://example.com")

      expect(result).to be_transport_error
      expect(result.status).to be_nil
    end

    it "still logs the response status and never the body" do
      stub_response(201, '{"token":"tok-secret-value","base_url":"https://example.com"}')

      described_class.token_result("https://example.com")

      expect(logger).to have_received(:info) do |message|
        expect(message).to include("201")
        expect(message).not_to include("tok-secret-value")
      end
    end

    # A 2xx that carried nothing the cache can key on is a broken server, and
    # saying so with the real 2xx status attached is truthful -- intake's
    # base_url is NOT NULL and it answers 422 rather than minting when the URL
    # resolves to nothing, so a 2xx without one cannot be anything else.
    it "reports a 2xx with no token as a server error carrying the real 2xx status" do
      stub_response(201, JSON.generate(base_url: "https://example.com"))

      result = described_class.token_result("https://example.com")

      expect(result).to be_server_error
      expect(result).not_to be_success
      expect(result.status).to eq(201)
      # The payload still comes back: `token` below depends on it.
      expect(result.payload).to eq(base_url: "https://example.com")
    end

    it "reports a 2xx with a token but no base_url as a server error too" do
      stub_response(201, JSON.generate(token: "tok"))

      result = described_class.token_result("https://example.com")

      expect(result).to be_server_error
      expect(result).not_to be_success
      expect(result.status).to eq(201)
      expect(result.payload).to eq(token: "tok")
    end

    # intake sends an error document with a 4xx, never with a 2xx, so a 2xx
    # carrying one is a server contradicting itself. It is still classified on
    # the status it really sent rather than on what the body looks like it
    # meant -- a 200 is not retroactively a 422 because it apologised.
    it "reports a 2xx carrying an error where a token should be as a server error" do
      stub_response(200, JSON.generate(error: "Missing target application"))

      result = described_class.token_result("https://example.com")

      expect(result).to be_server_error
      expect(result).not_to be_success
      expect(result).not_to be_request_rejected
      expect(result.status).to eq(200)
      expect(result.payload).to eq(error: "Missing target application")
    end

    # "" is truthy in Ruby, so the truthiness check this replaced called an
    # empty token a mint and handed the caller an empty bearer token to send.
    it "reports a 2xx with an empty token as a server error" do
      stub_response(201, JSON.generate(token: "", base_url: "https://example.com"))

      result = described_class.token_result("https://example.com")

      expect(result).to be_server_error
      expect(result).not_to be_success
      expect(result.status).to eq(201)
      expect(result.payload).to eq(token: "", base_url: "https://example.com")
    end

    # An empty base_url is not a key. A token cached under one can be matched
    # by no lookup that ever runs, so it would be minted and lost again on
    # every single call.
    it "reports a 2xx with an empty base_url as a server error" do
      stub_response(201, JSON.generate(token: "tok", base_url: ""))

      result = described_class.token_result("https://example.com")

      expect(result).to be_server_error
      expect(result).not_to be_success
      expect(result.status).to eq(201)
      expect(result.payload).to eq(token: "tok", base_url: "")
    end

    it "reports a 2xx whose token is not a string at all as a server error" do
      stub_response(201, JSON.generate(token: { value: "tok" }, base_url: "https://example.com"))

      result = described_class.token_result("https://example.com")

      expect(result).to be_server_error
      expect(result).not_to be_success
      expect(result.status).to eq(201)
    end

    # Deliberate: five honest outcome names, and no single boolean folding
    # them back into two. Such a boolean is one more thing that can answer
    # wrongly for a 400 or a 422, which is a smaller version of the bug this
    # whole change removes.
    it "exposes no retry/no-retry boolean that would collapse the outcomes" do
      stub_response(401, JSON.generate(error: "nope"))

      result = described_class.token_result("https://example.com")

      expect(result).not_to respond_to(:retriable?)
    end

    it "answers failure? for every outcome that is not a success" do
      stub_response(422, JSON.generate(error: "Missing target application"))
      expect(described_class.token_result("https://example.com")).to be_failure

      stub_response(201, JSON.generate(token: "tok", base_url: "https://example.com"))
      expect(described_class.token_result("https://example.com")).not_to be_failure
    end

    it "returns a frozen value object that cannot be edited in place" do
      stub_response(401, JSON.generate(error: "nope"))

      result = described_class.token_result("https://example.com")

      expect(result).to be_frozen
      expect { result.instance_variable_set(:@outcome, :success) }.to raise_error(FrozenError)
    end
  end

  # sc-189. `token` is the body-or-nil accessor, and a body means a token was
  # actually minted -- matching Elixir, which has always answered nil for
  # anything that was not a mint. Nothing in `lib` calls this: AccessTokens
  # reads `token_result(base_url).payload`, so nil here costs no diagnostic.
  describe ".token legacy contract" do
    it "answers nil for a non-2xx response rather than its error body" do
      allow(Excon).to receive(:post).and_return(
        double("response", status: 422, body: JSON.generate(error: "Missing target application"))
      )

      expect(described_class.token("https://example.com")).to be_nil
    end

    it "answers nil for a 401, leaving the reason to token_result" do
      allow(Excon).to receive(:post).and_return(
        double("response", status: 401, body: JSON.generate(error: "invalid credentials"))
      )

      expect(described_class.token("https://example.com")).to be_nil
      expect(described_class.token_result("https://example.com").payload)
        .to eq(error: "invalid credentials")
    end

    # Handing these back would give a caller a truthy value for a request that
    # produced no token -- the failure `token_result` exists to remove, one
    # layer down. The body stays reachable on the result.
    it "answers nil for a 2xx that carried no token" do
      allow(Excon).to receive(:post).and_return(
        double("response", status: 200, body: JSON.generate(base_url: "https://example.com", note: "none here"))
      )

      expect(described_class.token("https://example.com")).to be_nil
      expect(described_class.token_result("https://example.com").payload)
        .to eq(base_url: "https://example.com", note: "none here")
    end

    it "answers nil for a 2xx whose token was empty" do
      allow(Excon).to receive(:post).and_return(
        double("response", status: 200, body: JSON.generate(token: "", base_url: "https://example.com"))
      )

      expect(described_class.token("https://example.com")).to be_nil
    end

    it "answers the symbolized body when a token really was minted" do
      allow(Excon).to receive(:post).and_return(
        double("response", status: 200, body: JSON.generate(token: "tok-1", base_url: "https://example.com"))
      )

      expect(described_class.token("https://example.com"))
        .to eq(token: "tok-1", base_url: "https://example.com")
    end

    it "still returns nil when the body will not parse" do
      allow(Excon).to receive(:post).and_return(double("response", status: 200, body: "not json"))

      expect(described_class.token("https://example.com")).to be_nil
      expect(logger).to have_received(:error).with(/Error occurred during authentication/)
    end
  end
end
