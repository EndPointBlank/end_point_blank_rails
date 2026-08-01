# frozen_string_literal: true

require "spec_helper"

# Proves the cache-hit expiry check in EndPointBlank::AccessTokens#token uses
# plain Ruby `Time.now + 120` (2 minutes) rather than ActiveSupport's
# `2.minutes.from_now`, which raises NoMethodError (rescue-swallowed by the
# surrounding mutex block having no rescue -- it actually bubbles right out
# of `token`) when ActiveSupport is not loaded, as is the case for a plain
# Ruby / Sinatra host application.
# rubocop:disable Metrics/BlockLength
RSpec.describe EndPointBlank::AccessTokens do
  let(:instance) { described_class.instance }
  let(:hostname) { "access-tokens-spec.example.test" }

  after do
    instance.instance_variable_get(:@tokens).delete(hostname)
    instance.instance_variable_get(:@mutexes).delete(hostname)
  end

  def seed_cached_token(expires_at:)
    instance.instance_variable_get(:@tokens)[hostname] = { token: "cached-token", expired_at: expires_at }
    instance.instance_variable_get(:@mutexes)[hostname] ||= Mutex.new
  end

  it "does not raise NoMethodError (ActiveSupport is not loaded in this spec environment)" do
    expect(defined?(ActiveSupport)).to be_nil
  end

  it "treats a token expiring 5 minutes out as still valid and returns the cached token" do
    seed_cached_token(expires_at: Time.now + (5 * 60))

    expect(EndPointBlank::Commands::GenerateAccessToken).not_to receive(:token)
    expect(instance.token(hostname)).to eq("cached-token")
  end

  it "treats a token expiring 1 minute out as expired and fetches a fresh token" do
    seed_cached_token(expires_at: Time.now + 60)

    allow(EndPointBlank::Commands::GenerateAccessToken).to receive(:token)
      .with(hostname)
      .and_return(token: "fresh-token", expired_at: (Time.now + 3600).iso8601)

    expect(instance.token(hostname)).to eq("fresh-token")
  end

  # Regression: a freshly-fetched token's `expired_at` (an ISO8601 String from
  # the wire) must be parsed into a plain Time, not a DateTime -- comparing
  # DateTime > Time raises `ArgumentError: comparison of DateTime with Time
  # failed` in plain Ruby (no ActiveSupport patches this), which would have
  # crashed the *very next* cache-hit lookup for the same hostname.
  it "serves a second cache-hit lookup from a freshly-fetched token without raising" do
    allow(EndPointBlank::Commands::GenerateAccessToken).to receive(:token)
      .with(hostname)
      .and_return(token: "fresh-token", expired_at: (Time.now + 3600).iso8601)

    first = instance.token(hostname)

    second = nil
    expect { second = instance.token(hostname) }.not_to raise_error

    expect(first).to eq("fresh-token")
    expect(second).to eq("fresh-token")
    expect(EndPointBlank::Commands::GenerateAccessToken).to have_received(:token).once
  end
end
# rubocop:enable Metrics/BlockLength

# The token cache in front of the intake's token endpoint. Everything here
# drives the real singleton and stubs only Excon, the network boundary that
# EndPointBlank::Commands::GenerateAccessToken posts through.
#
# rubocop:disable Metrics/BlockLength
RSpec.describe "EndPointBlank::AccessTokens against the token endpoint" do
  let(:instance) { EndPointBlank::AccessTokens.instance }
  let(:configuration) { EndPointBlank::Configuration.instance }
  let(:logger) { double("logger", info: nil, error: nil, warn: nil) }
  let(:hostname) { "tokens.example.test" }
  let(:issued) { %w[tok-1 tok-2 tok-3] }
  let(:token_lifetime) { 3600 }

  around do |example|
    original_ttl = configuration.token_ttl

    example.run

    configuration.token_ttl = original_ttl
    instance.clear(nil)
  end

  before do
    allow(EndPointBlank).to receive(:logger).and_return(logger)
    configuration.client_id = "cid"
    configuration.client_secret = "csecret"
    instance.clear(nil)

    allow(Excon).to receive(:post) do
      double(
        "response",
        status: 200,
        body: JSON.generate(token: issued.shift, expired_at: (Time.now + token_lifetime).utc.iso8601)
      )
    end
  end

  it "issues a token for a hostname" do
    expect(instance.token(hostname)).to eq("tok-1")
  end

  it "reuses a live token instead of asking for a new one on every request" do
    instance.token(hostname)
    instance.token(hostname)

    expect(Excon).to have_received(:post).once
  end

  # Hostnames arrive from the Host header, whose casing is the caller's choice.
  # Treating them as distinct would mean a fresh token exchange per casing.
  it "treats a hostname as case-insensitive" do
    instance.token("Tokens.Example.Test")
    instance.token("tokens.example.test")

    expect(Excon).to have_received(:post).once
  end

  it "keeps a separate token per hostname" do
    expect(instance.token("one.example.test")).to eq("tok-1")
    expect(instance.token("two.example.test")).to eq("tok-2")
  end

  it "reports a live token as present, and an unknown hostname as absent" do
    instance.token(hostname)

    expect(instance.exists?(hostname)).to be(true)
    expect(instance.exists?("never-seen.example.test")).to be(false)
  end

  it "treats a token that is about to expire as absent" do
    # Callers use exists? to decide whether they can proceed without a round
    # trip; a token with seconds left on it would expire mid-flight.
    allow(Excon).to receive(:post).and_return(
      double("response", status: 200, body: JSON.generate(token: "expiring", expired_at: (Time.now + 5).utc.iso8601))
    )
    instance.token(hostname)

    expect(instance.exists?(hostname)).to be(false)
  end

  it "exchanges again after the token is removed" do
    instance.token(hostname)
    instance.remove(hostname)

    expect(instance.token(hostname)).to eq("tok-2")
  end

  it "exchanges again for every hostname after a clear" do
    instance.token("one.example.test")
    instance.token("two.example.test")

    instance.clear(nil)

    expect(instance.token("one.example.test")).to eq("tok-3")
  end

  it "passes the configured token lifetime to the intake" do
    configuration.token_ttl = 900

    instance.token(hostname)

    expect(Excon).to have_received(:post).with(
      configuration.access_token_url,
      hash_including(body: include('"token_ttl":900'))
    )
  end

  it "omits the token lifetime when none is configured" do
    configuration.token_ttl = nil

    instance.token(hostname)

    expect(Excon).to have_received(:post).with(
      configuration.access_token_url,
      hash_including(body: '{"hostname":"tokens.example.test"}')
    )
  end

  describe "when the intake will not issue a token" do
    # Regression: this branch used Hash#fetch with a string key against a
    # symbol-keyed hash, so the code path that exists to fail gracefully
    # raised KeyError instead -- a 500 produced by the logging of an error.
    it "returns nil and logs the reason the intake gave" do
      allow(Excon).to receive(:post).and_return(
        double("response", status: 403, body: JSON.generate(error: "client credentials revoked"))
      )

      result = nil
      expect { result = instance.token(hostname) }.not_to raise_error

      expect(result).to be_nil
      expect(logger).to have_received(:error).with(/client credentials revoked/)
    end

    it "returns nil and says so when the intake could not be reached at all" do
      allow(Excon).to receive(:post).and_raise(Excon::Error::Timeout.new("timed out"))

      result = nil
      expect { result = instance.token(hostname) }.not_to raise_error

      expect(result).to be_nil
      expect(logger).to have_received(:error).with(/no response/)
    end

    it "does not cache the failure, so the next request tries again" do
      allow(Excon).to receive(:post).and_return(double("response", status: 500, body: "{}"))
      instance.token(hostname)

      allow(Excon).to receive(:post).and_return(
        double("response", status: 200, body: JSON.generate(token: "recovered", expired_at: (Time.now + 3600).utc.iso8601))
      )

      expect(instance.token(hostname)).to eq("recovered")
    end
  end
end
# rubocop:enable Metrics/BlockLength
