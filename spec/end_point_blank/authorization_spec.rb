# frozen_string_literal: true

require "spec_helper"

RSpec.describe EndPointBlank::Authorization do
  let(:configuration) { EndPointBlank::Configuration.instance }
  let(:logger) { double("logger", info: nil, error: nil, warn: nil) }
  let(:base_url) { "https://authorization-spec.example.test/orders" }

  around do |example|
    original = %i[@client_id @client_secret].each_with_object({}) do |ivar, memo|
      memo[ivar] = configuration.instance_variable_get(ivar)
    end

    example.run

    original.each { |ivar, value| configuration.instance_variable_set(ivar, value) }
    EndPointBlank::AccessTokens.instance.clear
  end

  before do
    allow(EndPointBlank).to receive(:logger).and_return(logger)
    configuration.client_id = "cid"
    configuration.client_secret = "csecret"
    EndPointBlank::AccessTokens.instance.clear
  end

  let(:basic) { "Basic #{Base64.strict_encode64("cid:csecret")}" }
  let(:calls) { [] }

  # Every Excon.post is recorded, with the header it carried, so a test can
  # assert on everything that went over the wire -- not only on what `header`
  # returned.
  def record_posts(&answer)
    allow(Excon).to receive(:post) do |url, options|
      calls << { url: url, auth: options[:headers]["Authorization"] }
      answer.call(url)
    end
  end

  def minted(token = "abc")
    double("response", status: 201,
                       body: JSON.generate(token: token, expired_at: (Time.now + 3600).utc.iso8601,
                                           base_url: base_url))
  end

  # What an integrator's outbound call looks like: build the header for the
  # provider URL, then call the provider with it. If `header` raises, the
  # provider is never called at all.
  def call_provider
    Excon.post(base_url, headers: { "Authorization" => described_class.header(base_url) })
  end

  describe ".header (outbound calls to a provider)" do
    it "answers Bearer with a token covering base_url when one can be obtained" do
      record_posts { minted }

      expect(described_class.header(base_url)).to eq("Bearer abc")
    end

    it "sends Bearer, never Basic, to the provider" do
      record_posts { |url| url == base_url ? double("response", status: 200, body: "") : minted }

      call_provider

      provider_calls = calls.select { |c| c[:url] == base_url }
      expect(provider_calls.map { |c| c[:auth] }).to eq(["Bearer abc"])
    end

    it "reuses a cached token without calling intake while intake is down" do
      record_posts { minted }
      described_class.header(base_url)
      calls.clear
      allow(Excon).to receive(:post).and_raise(Excon::Error::Timeout.new("timed out"))

      expect(described_class.header("#{base_url}/42")).to eq("Bearer abc")
    end

    # sc-1469: before this, every one of these fell back to
    # "Basic base64(client_id:client_secret)" -- which sent this service's own
    # credential to the provider it was calling.
    #
    # These lambdas run outside any example, where `double` is not available,
    # so they build a plain response instead.
    #
    # The reason in the message is one fixed text per outcome, the same in
    # every EndPointBlank SDK, and never intake's response body or an
    # exception message -- so each is pinned exactly.
    fake = Struct.new(:status, :body)
    {
      "the mint times out" => [
        -> { raise Excon::Error::Timeout, "timed out" }, :transport_error, nil,
        "intake could not be reached (timeout, connection refused or retries exhausted); this may be transient"
      ],
      "intake rejects the credential (401)" => [
        -> { fake.new(401, JSON.generate(error: "invalid credentials")) },
        :credential_rejected, 401,
        "intake rejected this application's client credential (HTTP 401); retrying cannot help -- " \
        "re-issue the credential"
      ],
      "intake refuses the request (422)" => [
        -> { fake.new(422, JSON.generate(error: "no such environment")) },
        :request_rejected, 422,
        "intake refused the token request (HTTP 422); check the URL and that a grant covers the target"
      ],
      "intake fails (500)" => [
        -> { fake.new(500, "oops") }, :server_error, 500,
        "intake failed to issue a token (HTTP 500); this may be transient"
      ],
      "the response carries a token but no base_url" => [
        lambda {
          fake.new(201, JSON.generate(token: "abc", expired_at: (Time.now + 3600).utc.iso8601))
        },
        :server_error, 201, "intake failed to issue a token (HTTP 201); this may be transient"
      ]
    }.each do |situation, (answer, outcome, status, reason)|
      context "when #{situation}" do
        before { record_posts { |url| url == base_url ? raise("provider must not be called") : answer.call } }

        it "raises TokenUnavailableError saying why and that credentials are never sent" do
          expect { described_class.header(base_url) }.to raise_error(EndPointBlank::TokenUnavailableError) { |error|
            expect(error).to be_a(EndPointBlank::Error)
            expect(error.base_url).to eq(base_url)
            expect(error.outcome).to eq(outcome)
            expect(error.status).to eq(status)
            expect(error.failure).to eq(EndPointBlank::AccessTokens.last_failure(base_url))
            expect(error.message).to eq(
              "Could not mint an EndPointBlank access token for #{base_url}: #{reason}. " \
              "EndPointBlank never sends this service's client_id/client_secret to a provider, " \
              "so there is no Basic-auth fallback and the call must not be made without a token."
            )
            expect(error.message).not_to include("csecret")
            # intake's body stays on failure.reason, out of the message.
            ["invalid credentials", "no such environment", "oops", "no base_url"].each do |body_text|
              expect(error.message).not_to include(body_text)
            end
          }
        end

        it "never calls the provider, and sends Basic only to its own intake's token endpoint" do
          expect { call_provider }.to raise_error(EndPointBlank::TokenUnavailableError)

          expect(calls).not_to be_empty
          expect(calls.map { |c| c[:url] }.uniq).to eq([configuration.access_token_url])
          expect(calls.select { |c| c[:url] != configuration.access_token_url && c[:auth].to_s.start_with?("Basic ") })
            .to be_empty
        end
      end
    end

    it "words the error exactly, reason included" do
      record_posts { double("response", status: 401, body: JSON.generate(error: "invalid credentials")) }

      expect { described_class.header(base_url) }.to raise_error(
        EndPointBlank::TokenUnavailableError,
        "Could not mint an EndPointBlank access token for https://authorization-spec.example.test/orders: " \
        "intake rejected this application's client credential (HTTP 401); retrying cannot help -- " \
        "re-issue the credential. EndPointBlank never sends this service's client_id/client_secret to a " \
        "provider, so there is no Basic-auth fallback and the call must not be made without a token."
      )
    end

    it "says so when no reason was recorded" do
      expect(EndPointBlank::TokenUnavailableError.new(base_url).message).to eq(
        "Could not mint an EndPointBlank access token for #{base_url}: the token request failed for an " \
        "unknown reason. EndPointBlank never sends this service's client_id/client_secret to a provider, " \
        "so there is no Basic-auth fallback and the call must not be made without a token."
      )
    end

    # sc-1469 review ruling (c): intake refuses a base_url carrying userinfo,
    # a query or a fragment, so sending them would both leak them and fail
    # the mint. They are removed before the request, and nothing else about
    # the call changes.
    describe "a URL carrying userinfo, a query and a fragment" do
      let(:raw) { "https://user:hunter2@authorization-spec.example.test/orders?api_key=s3cret#frag" }
      let(:secrets) { %w[user hunter2 api_key s3cret frag] }

      it "mints, sending intake only the stripped URL" do
        bodies = []
        allow(Excon).to receive(:post) do |_url, options|
          bodies << JSON.parse(options[:body])
          minted
        end

        expect(described_class.header(raw)).to eq("Bearer abc")
        expect(bodies.map { |b| b["base_url"] }).to eq([base_url])
      end

      it "keeps them off the error, its message and every log line" do
        record_posts { double("response", status: 401, body: JSON.generate(error: "invalid credentials")) }
        logged = []
        allow(logger).to receive(:error) { |line| logged << line }
        allow(logger).to receive(:info) { |line| logged << line }

        expect { described_class.header(raw) }.to raise_error(EndPointBlank::TokenUnavailableError) { |error|
          expect(error.base_url).to eq(base_url)
          expect(error.failure.base_url).to eq(base_url)
          secrets.each do |secret|
            expect(error.message).not_to include(secret)
            logged.each { |line| expect(line).not_to include(secret) }
          end
        }
        expect(logged).not_to be_empty
        recorded = EndPointBlank::AccessTokens.last_failure(base_url)
        expect(EndPointBlank::AccessTokens.last_failure(raw)).to equal(recorded)
      end
    end

    it "refuses an unparseable URL without any request and without repeating it" do
      record_posts { raise "no request may be made" }

      ["not a url ?token=s3cret", "orders/42?token=s3cret", "https://?token=s3cret"].each do |bad|
        expect { described_class.header(bad) }.to raise_error(ArgumentError, /could not parse/) { |error|
          expect(error.message).not_to include("s3cret")
        }
      end
      expect(calls).to be_empty
    end

    # sc-1469 review: `header` used to call `token` and then `last_failure`
    # after the cache's mutex was released, so another thread could clear the
    # record (a successful mint for the same URL) or overwrite it (its own
    # failed mint) in between, and the error reported someone else's reason
    # or none. Each example below does that other thread's work at exactly
    # that moment -- right after this call's mint returns.
    describe "reporting this call's own failure, not the shared record" do
      let(:answer) { { status: 401, body: JSON.generate(error: "invalid credentials") } }

      before do
        record_posts { double("response", **answer) }
      end

      def after_this_mint(&other_thread)
        allow(EndPointBlank::AccessTokens.instance).to receive(:token_result).and_wrap_original do |original, url|
          result = original.call(url)
          other_thread.call
          result
        end
      end

      it "when another thread clears the record straight after" do
        after_this_mint { EndPointBlank::AccessTokens.instance.clear }

        expect { described_class.header(base_url) }.to raise_error(EndPointBlank::TokenUnavailableError) { |error|
          expect(EndPointBlank::AccessTokens.last_failure(base_url)).to be_nil
          expect(error.outcome).to eq(:credential_rejected)
          expect(error.status).to eq(401)
          expect(error.message).to include("intake rejected this application's client credential (HTTP 401)")
        }
      end

      it "when another thread's failed mint overwrites the record straight after" do
        after_this_mint do
          answer.replace(status: 500, body: "oops")
          # Straight to GenerateAccessToken's result through the cache's own
          # recording path, bypassing the wrapper above.
          EndPointBlank::AccessTokens.instance.send(
            :record_failure, base_url, EndPointBlank::Commands::GenerateAccessToken.token_result(base_url)
          )
        end

        expect { described_class.header(base_url) }.to raise_error(EndPointBlank::TokenUnavailableError) { |error|
          expect(EndPointBlank::AccessTokens.last_failure(base_url).outcome).to eq(:server_error)
          expect(error.outcome).to eq(:credential_rejected)
          expect(error.status).to eq(401)
          expect(error.message).to include("intake rejected this application's client credential (HTTP 401)")
        }
      end

      it "never reads the shared record at all" do
        allow(EndPointBlank::AccessTokens).to receive(:last_failure).and_call_original

        expect { described_class.header(base_url) }.to raise_error(EndPointBlank::TokenUnavailableError)
        expect(EndPointBlank::AccessTokens).not_to have_received(:last_failure)
      end
    end

    it "raises ConfigurationError, sending nothing, when the client credentials are missing" do
      record_posts { minted }
      configuration.client_secret = nil
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("ENDPOINTBLANK_CLIENT_SECRET").and_return(nil)

      expect { described_class.header(base_url) }.to raise_error(EndPointBlank::ConfigurationError, /client_secret/)
      expect(calls).to be_empty
    end

    it "has no no-target form: calling it without a URL is an ArgumentError" do
      record_posts { minted }

      expect { described_class.header }.to raise_error(ArgumentError)
      expect { described_class.header(nil) }.to raise_error(ArgumentError, /URL you are about to call/)
      expect { described_class.header("") }.to raise_error(ArgumentError, /URL you are about to call/)
      expect(calls).to be_empty
    end
  end

  describe ".intake_header (the SDK's own calls to its own intake)" do
    it "uses the client credentials" do
      expect(described_class.intake_header).to eq(basic)
    end

    it "never emits a newline, which would truncate or corrupt the header" do
      # Base64.encode64 line-wraps at 60 characters, and real client ids and
      # secrets are long enough to reach that.
      configuration.client_id = "c" * 60
      configuration.client_secret = "s" * 60

      expect(described_class.intake_header).not_to include("\n")
    end

    # sc-1469 turned `client_id + ":" + client_secret` (which raised on nil)
    # into interpolation, which would quietly send `Basic Og==` -- base64 of
    # ":" -- and have intake reject it as though the credential were revoked.
    context "when a client credential is missing" do
      before do
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("ENDPOINTBLANK_CLIENT_ID").and_return(nil)
        allow(ENV).to receive(:[]).with("ENDPOINTBLANK_CLIENT_SECRET").and_return(nil)
      end

      {
        "client_id is nil" => [{ client_id: nil }, /missing client_id:/],
        "client_id is empty" => [{ client_id: "" }, /missing client_id:/],
        "client_secret is nil" => [{ client_secret: nil }, /missing client_secret:/],
        "client_secret is empty" => [{ client_secret: "" }, /missing client_secret:/],
        "both are nil" => [{ client_id: nil, client_secret: nil }, /missing client_id and client_secret:/]
      }.each do |situation, (settings, message)|
        it "raises ConfigurationError when #{situation}, never sending Basic Og==" do
          settings.each { |key, value| configuration.public_send(:"#{key}=", value) }

          expect { described_class.intake_header }.to raise_error(EndPointBlank::ConfigurationError, message) { |error|
            expect(error).to be_a(EndPointBlank::Error)
            expect(error.message).not_to include("csecret")
          }
        end
      end

      it "stops the SDK's own calls to intake instead of sending an empty credential" do
        record_posts { double("response", status: 201, body: "{}") }
        configuration.client_id = nil

        expect { EndPointBlank::Writers::DirectWriter.new("https://intake.example.test/logs").write([{ a: 1 }]) }
          .to raise_error(EndPointBlank::ConfigurationError)
        expect(calls).to be_empty
      end
    end
  end

  describe "own-intake calls keep presenting Basic and never mint a token" do
    before { record_posts { double("response", status: 201, body: "{}") } }

    it "DirectWriter (log/request/response writers)" do
      EndPointBlank::Writers::DirectWriter.new("https://intake.example.test/logs").write([{ a: 1 }])

      expect(calls).to eq([{ url: "https://intake.example.test/logs", auth: basic }])
    end

    it "EndpointUpdate" do
      EndPointBlank::Commands::EndpointUpdate.new.write(application: "a", environment: "e", app_version: "1")

      expect(calls).to eq([{ url: configuration.endpoint_update_url, auth: basic }])
    end

    it "the token mint itself" do
      EndPointBlank::Commands::GenerateAccessToken.token_result(base_url)

      expect(calls).to eq([{ url: configuration.access_token_url, auth: basic }])
    end
  end
end

RSpec.describe EndPointBlank::Commands::BearerGenerate do
  let(:configuration) { EndPointBlank::Configuration.instance }

  around do |example|
    original = %i[@client_id @client_secret].each_with_object({}) do |ivar, memo|
      memo[ivar] = configuration.instance_variable_get(ivar)
    end

    example.run

    original.each { |ivar, value| configuration.instance_variable_set(ivar, value) }
  end

  before do
    configuration.client_id = "cid"
    configuration.client_secret = "csecret"
  end

  it "encodes the client credentials as a single Base64 line" do
    expect(described_class.generate).to eq(Base64.strict_encode64("cid:csecret"))
  end

  it "does not wrap long credentials across lines" do
    configuration.client_id = "c" * 60
    configuration.client_secret = "s" * 60

    expect(described_class.generate).not_to include("\n")
  end

  it "builds a complete Basic header" do
    expect(described_class.auth_header).to eq("Basic #{Base64.strict_encode64("cid:csecret")}")
  end

  describe "the runtime deprecation warning" do
    around do |example|
      deprecated = Warning[:deprecated]
      Warning[:deprecated] = true
      described_class.remove_instance_variable(:@deprecation_warned) if described_class.instance_variable_defined?(:@deprecation_warned)
      example.run
    ensure
      Warning[:deprecated] = deprecated
    end

    it "is emitted once, through the :deprecated category, however many times it is called" do
      allow(Warning).to receive(:warn).and_call_original

      expect do
        described_class.generate
        described_class.auth_header
        described_class.generate
      end.to output(/BearerGenerate is deprecated.*Authorization\.header\(base_url\)/).to_stderr

      expect(Warning).to have_received(:warn).with(/BearerGenerate is deprecated/, category: :deprecated).once
    end

    it "is emitted from auth_header too" do
      expect { described_class.auth_header }.to output(/BearerGenerate is deprecated/).to_stderr
    end

    it "is silent while Ruby's deprecation warnings are off" do
      Warning[:deprecated] = false

      expect { described_class.generate }.not_to output.to_stderr
    end
  end
end
