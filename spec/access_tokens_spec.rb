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

  after { instance.clear }

  # Seeds through the public path rather than the ivars, so these keep meaning
  # something if the cache is reshaped again.
  def cache_token_expiring_in(seconds)
    allow(EndPointBlank::Commands::GenerateAccessToken).to receive(:token)
      .and_return(token: "cached-token", expired_at: (Time.now + seconds).iso8601)
    instance.token(hostname)
  end

  it "does not raise NoMethodError (ActiveSupport is not loaded in this spec environment)" do
    expect(defined?(ActiveSupport)).to be_nil
  end

  it "treats a token expiring 5 minutes out as still valid and returns the cached token" do
    cache_token_expiring_in(5 * 60)

    expect(instance.token(hostname)).to eq("cached-token")
    expect(EndPointBlank::Commands::GenerateAccessToken).to have_received(:token).once
  end

  it "treats a token expiring 1 minute out as expired and fetches a fresh token" do
    cache_token_expiring_in(60)

    allow(EndPointBlank::Commands::GenerateAccessToken).to receive(:token)
      .and_return(token: "fresh-token", expired_at: (Time.now + 3600).iso8601)

    expect(instance.token(hostname)).to eq("fresh-token")
  end

  # Regression: a freshly-fetched token's `expired_at` (an ISO8601 String from
  # the wire) must be parsed into a plain Time, not a DateTime -- comparing
  # DateTime > Time raises `ArgumentError: comparison of DateTime with Time
  # failed` in plain Ruby (no ActiveSupport patches this), which would have
  # crashed the *very next* cache-hit lookup.
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
    instance.clear
  end

  before do
    allow(EndPointBlank).to receive(:logger).and_return(logger)
    configuration.client_id = "cid"
    configuration.client_secret = "csecret"
    instance.clear

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

  # The intake binds a token to the application environment the credential
  # belongs to, not to the hostname the request names -- one process
  # authenticates as one application environment, so one token covers it.
  # Keying on the hostname meant the Host header, which the caller chooses,
  # could drive a token exchange and an intake database lookup per novel value.
  it "serves every hostname from the one token" do
    expect(instance.token("one.example.test")).to eq("tok-1")
    expect(instance.token("two.example.test")).to eq("tok-1")
    expect(instance.token("never-seen.example.test")).to eq("tok-1")

    expect(Excon).to have_received(:post).once
  end

  it "serves a live token without asking, so a refused hostname cannot disturb it" do
    instance.token(hostname)
    allow(Excon).to receive(:post).and_return(
      double("response", status: 422, body: JSON.generate(error: "revoked"))
    )

    expect(instance.token("anything.example.test")).to eq("tok-1")
    expect(instance.exists?).to be(true)
  end

  it "discards the token it could not replace when a refresh fails" do
    # Only a token already inside the refresh buffer reaches an exchange, so the
    # one left behind is always close to death. Keeping it means exists? --
    # whose floor is 30 seconds -- goes on calling it usable, and a caller
    # acting on that presents a credential the intake is about to reject.
    allow(Excon).to receive(:post).and_return(
      double("response", status: 200,
                         body: JSON.generate(token: "nearly-dead", expired_at: (Time.now + 60).utc.iso8601))
    )
    instance.token(hostname)

    allow(Excon).to receive(:post).and_return(
      double("response", status: 422, body: JSON.generate(error: "revoked"))
    )

    expect(instance.token(hostname)).to be_nil
    expect(instance.exists?).to be(false)
  end

  it "reports a live token as present" do
    instance.token(hostname)

    expect(instance.exists?).to be(true)
  end

  it "reports no token as absent before anything has been issued" do
    expect(instance.exists?).to be(false)
  end

  it "treats a token that is about to expire as absent" do
    # Callers use exists? to decide whether they can proceed without a round
    # trip; a token with seconds left on it would expire mid-flight.
    allow(Excon).to receive(:post).and_return(
      double("response", status: 200, body: JSON.generate(token: "expiring", expired_at: (Time.now + 5).utc.iso8601))
    )
    instance.token(hostname)

    expect(instance.exists?).to be(false)
  end

  it "exchanges again after the current token is invalidated" do
    first = instance.token(hostname)
    instance.invalidate(first)

    expect(instance.token(hostname)).to eq("tok-2")
  end

  # What stops a 401 from stampeding. Every request in flight when a token is
  # rejected reports the same stale value; only the first should cause an
  # exchange, because the rest are holding a token that has already been
  # replaced and clearing for them would discard a good one.
  it "ignores an invalidation for a token that has already been replaced" do
    first = instance.token(hostname)
    instance.invalidate(first)
    instance.token(hostname)

    instance.invalidate(first)

    expect(instance.token(hostname)).to eq("tok-2")
    expect(Excon).to have_received(:post).twice
  end

  it "ignores an invalidation with no token" do
    instance.token(hostname)

    instance.invalidate(nil)

    expect(instance.token(hostname)).to eq("tok-1")
    expect(Excon).to have_received(:post).once
  end

  it "exchanges again after a clear" do
    instance.token("one.example.test")

    instance.clear

    expect(instance.token("two.example.test")).to eq("tok-2")
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

  # Time.parse raises on anything it cannot read, and this runs inside the
  # mutex on the path a caller's request goes through -- so a malformed
  # timestamp from the intake came out of Authorization.header and into the
  # host application's request. An hour is a guess, but it is a working one:
  # treating the token as unusable instead would mean an exchange on every
  # inbound request for as long as the far end misbehaves, and if the token
  # really does die sooner the 401 retry invalidates it and mints another.
  describe "when the intake sends an expiry that cannot be read" do
    def issue_with_expiry(expired_at)
      allow(Excon).to receive(:post).and_return(
        double("response", status: 200, body: JSON.generate(token: "tok-1", expired_at: expired_at))
      )
    end

    it "keeps the token for an hour rather than raising, when the expiry is not a timestamp" do
      issue_with_expiry("whenever")

      expect { instance.token(hostname) }.not_to raise_error

      expect(instance.token(hostname)).to eq("tok-1")
      expect(instance.exists?).to be(true)
      expect(Excon).to have_received(:post).once
    end

    it "does the same when the expiry is not a string at all" do
      issue_with_expiry(1_735_689_600)

      expect(instance.token(hostname)).to eq("tok-1")
      expect(instance.exists?).to be(true)
    end

    it "does the same when the expiry is missing entirely" do
      allow(Excon).to receive(:post).and_return(
        double("response", status: 200, body: JSON.generate(token: "tok-1"))
      )

      expect(instance.token(hostname)).to eq("tok-1")
      expect(instance.exists?).to be(true)
    end
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
