# frozen_string_literal: true

require "spec_helper"

RSpec.describe EndPointBlank::Authorization do
  let(:configuration) { EndPointBlank::Configuration.instance }
  let(:logger) { double("logger", info: nil, error: nil, warn: nil) }
  let(:hostname) { "authorization-spec.example.test" }

  around do |example|
    original = %i[@client_id @client_secret].each_with_object({}) do |ivar, memo|
      memo[ivar] = configuration.instance_variable_get(ivar)
    end

    example.run

    original.each { |ivar, value| configuration.instance_variable_set(ivar, value) }
    EndPointBlank::AccessTokens.instance.clear(nil)
  end

  before do
    allow(EndPointBlank).to receive(:logger).and_return(logger)
    configuration.client_id = "cid"
    configuration.client_secret = "csecret"
    EndPointBlank::AccessTokens.instance.clear(nil)
  end

  describe ".header" do
    it "uses the client credentials when no hostname is given" do
      expect(described_class.header).to eq("Basic #{Base64.strict_encode64("cid:csecret")}")
    end

    it "uses a per-hostname access token when one can be obtained" do
      allow(Excon).to receive(:post).and_return(
        double("response", status: 200, body: JSON.generate(token: "abc", expired_at: (Time.now + 3600).utc.iso8601))
      )

      expect(described_class.header(hostname)).to eq("Bearer abc")
    end

    # Telemetry and authorization must keep working while the token endpoint is
    # down; the client credentials are accepted by intake too.
    it "falls back to the client credentials when no token can be obtained" do
      allow(Excon).to receive(:post).and_raise(Excon::Error::Timeout.new("timed out"))

      expect(described_class.header(hostname)).to start_with("Basic ")
    end

    it "never emits a newline, which would truncate or corrupt the header" do
      # Base64.encode64 line-wraps at 60 characters, and real client ids and
      # secrets are long enough to reach that.
      configuration.client_id = "c" * 60
      configuration.client_secret = "s" * 60

      expect(described_class.header).not_to include("\n")
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
