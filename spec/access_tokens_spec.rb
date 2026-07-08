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
