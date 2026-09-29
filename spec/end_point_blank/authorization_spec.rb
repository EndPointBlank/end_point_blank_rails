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
    fake = Struct.new(:status, :body)
    {
      "the mint times out" => [
        -> { raise Excon::Error::Timeout, "timed out" }, :transport_error, nil, /no response/
      ],
      "intake rejects the credential (401)" => [
        -> { fake.new(401, JSON.generate(error: "invalid credentials")) },
        :credential_rejected, 401, /invalid credentials/
      ],
      "intake refuses the request (422)" => [
        -> { fake.new(422, JSON.generate(error: "no such environment")) },
        :request_rejected, 422, /no such environment/
      ],
      "intake fails (500)" => [
        -> { fake.new(500, "oops") }, :server_error, 500, /HTTP 500/
      ],
      "the response carries a token but no base_url" => [
        lambda {
          fake.new(201, JSON.generate(token: "abc", expired_at: (Time.now + 3600).utc.iso8601))
        },
        :server_error, 201, /no base_url/
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
            expect(error.message).to include("could not mint an access token for #{base_url}")
            expect(error.message).to match(reason)
            expect(error.message).to include("never sends this service's client credentials to a provider")
            expect(error.message).not_to include("csecret")
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
end
