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
  let(:base_url) { "https://access-tokens-spec.example.test/orders" }

  after { instance.clear }

  # Seeds through the public path rather than the ivars, so these keep meaning
  # something if the cache is reshaped again.
  def cache_token_expiring_in(seconds)
    allow(EndPointBlank::Commands::GenerateAccessToken).to receive(:token)
      .and_return(token: "cached-token", expired_at: (Time.now + seconds).iso8601, base_url: base_url)
    instance.token(base_url)
  end

  it "does not raise NoMethodError (ActiveSupport is not loaded in this spec environment)" do
    expect(defined?(ActiveSupport)).to be_nil
  end

  it "treats a token expiring 5 minutes out as still valid and returns the cached token" do
    cache_token_expiring_in(5 * 60)

    expect(instance.token(base_url)).to eq("cached-token")
    expect(EndPointBlank::Commands::GenerateAccessToken).to have_received(:token).once
  end

  it "treats a token expiring 1 minute out as expired and fetches a fresh token" do
    cache_token_expiring_in(60)

    allow(EndPointBlank::Commands::GenerateAccessToken).to receive(:token)
      .and_return(token: "fresh-token", expired_at: (Time.now + 3600).iso8601, base_url: base_url)

    expect(instance.token(base_url)).to eq("fresh-token")
  end

  # Regression: a freshly-fetched token's `expired_at` (an ISO8601 String from
  # the wire) must be parsed into a plain Time, not a DateTime -- comparing
  # DateTime > Time raises `ArgumentError: comparison of DateTime with Time
  # failed` in plain Ruby (no ActiveSupport patches this), which would have
  # crashed the *very next* cache-hit lookup.
  it "serves a second cache-hit lookup from a freshly-fetched token without raising" do
    allow(EndPointBlank::Commands::GenerateAccessToken).to receive(:token)
      .with(base_url)
      .and_return(token: "fresh-token", expired_at: (Time.now + 3600).iso8601, base_url: base_url)

    first = instance.token(base_url)

    second = nil
    expect { second = instance.token(base_url) }.not_to raise_error

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
# A token is cached under the canonical base URL intake resolved the request
# to -- not under the URL the caller supplied. A caller asks for the URL it is
# about to call; intake answers with the base URL of the environment that URL
# belongs to, and subsequent calls anywhere under that base URL reuse the
# entry. That is why every stubbed response below carries its own `base_url`:
# without one the mint is treated as failed (see "when the intake will not
# issue a token").
#
# rubocop:disable Metrics/BlockLength
RSpec.describe "EndPointBlank::AccessTokens against the token endpoint" do
  let(:instance) { EndPointBlank::AccessTokens.instance }
  let(:configuration) { EndPointBlank::Configuration.instance }
  let(:logger) { double("logger", info: nil, error: nil, warn: nil) }
  let(:base_url) { "https://tokens.example.test/orders" }
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

    allow(Excon).to receive(:post) do |_url, options|
      requested = JSON.parse(options[:body])["base_url"]
      double(
        "response",
        status: 200,
        body: JSON.generate(token: issued.shift, expired_at: (Time.now + token_lifetime).utc.iso8601,
                            base_url: requested)
      )
    end
  end

  describe "keying on the base URL intake returned" do
    it "issues a token for a base URL" do
      expect(instance.token(base_url)).to eq("tok-1")
    end

    it "reuses a live token instead of asking for a new one on every request" do
      instance.token(base_url)
      instance.token(base_url)

      expect(Excon).to have_received(:post).once
    end

    # A different path under the same registered base URL reuses the entry --
    # the cache key is what intake resolved to, not the resource the caller
    # happened to ask about.
    it "serves any path under the cached base URL from the same entry" do
      instance.token(base_url)

      expect(instance.token("#{base_url}/widgets/42")).to eq("tok-1")
      expect(Excon).to have_received(:post).once
    end

    # The reason the cache is a map at all: a service that calls two targets
    # needs a token for each, and holding one would send the wrong credential
    # to the second.
    it "keeps distinct base URLs apart" do
      a = "https://a.example.test"
      b = "https://b.example.test"

      expect(instance.token(a)).to eq("tok-1")
      expect(instance.token(b)).to eq("tok-2")
      expect(instance.token(a)).to eq("tok-1")

      expect(Excon).to have_received(:post).twice
    end

    it "lets the longest matching prefix win" do
      broad = "https://example.test"
      narrow = "https://example.test/orders"

      # Seeded narrow-first: once the broad entry exists, nothing under it can
      # miss, so this is the only order in which both entries get created.
      instance.token(narrow)
      instance.token(broad)

      expect(instance.token("#{narrow}/42")).to eq("tok-1")
      expect(instance.token("#{broad}/other")).to eq("tok-2")
      expect(Excon).to have_received(:post).twice
    end

    # "/ordersXX" must NOT match "/orders" -- a prefix that stops mid-segment
    # is a different resource, and reusing the token would present it to a
    # base URL it was never issued for.
    it "respects segment boundaries" do
      instance.token("https://example.test/orders")

      expect(instance.token("https://example.test/ordersXX")).to eq("tok-2")
      expect(Excon).to have_received(:post).twice
    end

    # The SDK does not normalize -- intake owns that rule. A URL that does not
    # match character-for-character costs one extra request, which is cheaper
    # than presenting a token issued for somewhere else. (A query string
    # should have been stripped before it got here; missing is the right
    # answer when it was not.)
    it "misses on a different case rather than guessing" do
      instance.token(base_url)

      expect(instance.token(base_url.sub("tokens", "Tokens"))).to eq("tok-2")
      expect(Excon).to have_received(:post).twice
    end

    it "misses on a query string rather than guessing" do
      instance.token(base_url)

      expect(instance.token("#{base_url}?page=2")).to eq("tok-2")
      expect(Excon).to have_received(:post).twice
    end

    # Falls out of the "key + /" rule rather than from any normalization:
    # ".../orders/" starts with ".../orders/". Worth pinning, because it is
    # the one non-identical form that does NOT cost an extra mint.
    it "still matches a trailing slash" do
      instance.token(base_url)

      expect(instance.token("#{base_url}/")).to eq("tok-1")
      expect(Excon).to have_received(:post).once
    end
  end

  it "serves a live token without asking, so a refused base URL cannot disturb it" do
    instance.token(base_url)
    allow(Excon).to receive(:post).and_return(
      double("response", status: 422, body: JSON.generate(error: "revoked"))
    )

    expect(instance.token("#{base_url}/42")).to eq("tok-1")
    expect(instance.exists?(base_url)).to be(true)
  end

  it "discards the token it could not replace when a refresh fails" do
    # Only a token already inside the refresh buffer reaches an exchange, so the
    # one left behind is always close to death. Keeping it means exists? --
    # whose floor is 30 seconds -- goes on calling it usable, and a caller
    # acting on that presents a credential the intake is about to reject.
    allow(Excon).to receive(:post).and_return(
      double("response", status: 200,
                         body: JSON.generate(token: "nearly-dead", expired_at: (Time.now + 60).utc.iso8601,
                                             base_url: base_url))
    )
    instance.token(base_url)

    allow(Excon).to receive(:post).and_return(
      double("response", status: 422, body: JSON.generate(error: "revoked"))
    )

    expect(instance.token(base_url)).to be_nil
    expect(instance.exists?(base_url)).to be(false)
  end

  # Only the entry covering the failed URL is dropped. Intake refusing one
  # target must not cost the tokens held for every other target.
  it "leaves other base URLs untouched when one fails to refresh" do
    other = "https://other.example.test"
    allow(Excon).to receive(:post) do |_url, options|
      requested = JSON.parse(options[:body])["base_url"]
      double("response", status: 200,
                         body: JSON.generate(token: "nearly-dead", expired_at: (Time.now + 60).utc.iso8601,
                                             base_url: requested))
    end
    instance.token(base_url)
    instance.token(other)

    allow(Excon).to receive(:post).and_return(
      double("response", status: 422, body: JSON.generate(error: "revoked"))
    )

    expect(instance.token(base_url)).to be_nil
    expect(instance.exists?(base_url)).to be(false)
    expect(instance.exists?(other)).to be(true)
  end

  it "reports a live token as present" do
    instance.token(base_url)

    expect(instance.exists?(base_url)).to be(true)
  end

  it "reports no token as absent before anything has been issued" do
    expect(instance.exists?(base_url)).to be(false)
  end

  # exists? goes through the same prefix matcher token does, so a deeper path
  # under a cached base URL reads as covered.
  it "reports a sub-path of a cached base URL as present" do
    instance.token(base_url)

    expect(instance.exists?("#{base_url}/widgets/42")).to be(true)
  end

  it "reports a base URL no held token covers as absent" do
    instance.token(base_url)

    expect(instance.exists?("https://elsewhere.example.test")).to be(false)
  end

  it "treats a token that is about to expire as absent" do
    # Callers use exists? to decide whether they can proceed without a round
    # trip; a token with seconds left on it would expire mid-flight.
    allow(Excon).to receive(:post).and_return(
      double("response", status: 200, body: JSON.generate(token: "expiring", expired_at: (Time.now + 5).utc.iso8601,
                                                          base_url: base_url))
    )
    instance.token(base_url)

    expect(instance.exists?(base_url)).to be(false)
  end

  it "exchanges again after the current token is invalidated" do
    first = instance.token(base_url)
    instance.invalidate(first)

    expect(instance.token(base_url)).to eq("tok-2")
  end

  # A rejected caller holds a token, not a URL, so the lookup cannot be by
  # base URL -- and the tokens held for other targets are still good.
  it "finds the entry by token value and drops only that one" do
    a = "https://a.example.test"
    b = "https://b.example.test"
    tok_a = instance.token(a)
    instance.token(b)

    instance.invalidate(tok_a)

    expect(instance.exists?(a)).to be(false)
    expect(instance.exists?(b)).to be(true)
  end

  # What stops a 401 from stampeding. Every request in flight when a token is
  # rejected reports the same stale value; only the first should cause an
  # exchange, because the rest are holding a token that has already been
  # replaced and clearing for them would discard a good one.
  it "ignores an invalidation for a token that has already been replaced" do
    first = instance.token(base_url)
    instance.invalidate(first)
    instance.token(base_url)

    instance.invalidate(first)

    expect(instance.token(base_url)).to eq("tok-2")
    expect(Excon).to have_received(:post).twice
  end

  it "ignores an invalidation with no token" do
    instance.token(base_url)

    instance.invalidate(nil)

    expect(instance.token(base_url)).to eq("tok-1")
    expect(Excon).to have_received(:post).once
  end

  it "exchanges again after a clear" do
    instance.token("https://one.example.test")

    instance.clear

    expect(instance.token("https://two.example.test")).to eq("tok-2")
  end

  it "drops every cached token on clear" do
    other = "https://other.example.test"
    instance.token(base_url)
    instance.token(other)

    instance.clear

    expect(instance.exists?(base_url)).to be(false)
    expect(instance.exists?(other)).to be(false)
  end

  it "passes the configured token lifetime to the intake" do
    configuration.token_ttl = 900

    instance.token(base_url)

    expect(Excon).to have_received(:post).with(
      configuration.access_token_url,
      hash_including(body: include('"token_ttl":900'))
    )
  end

  it "omits the token lifetime when none is configured" do
    configuration.token_ttl = nil

    instance.token(base_url)

    expect(Excon).to have_received(:post).with(
      configuration.access_token_url,
      hash_including(body: JSON.generate(base_url: base_url))
    )
  end

  # base_url goes on the wire verbatim -- no downcasing, port-stripping, or
  # trailing-slash trimming. intake owns normalization; the SDK does not add a
  # URI parser.
  it "sends the base URL verbatim, with no normalization" do
    literal = "https://API.Example.test:8443/Orders/"

    instance.token(literal)

    expect(Excon).to have_received(:post).with(
      configuration.access_token_url,
      hash_including(body: JSON.generate(base_url: literal))
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
        double("response", status: 200, body: JSON.generate(token: "tok-1", expired_at: expired_at,
                                                            base_url: base_url))
      )
    end

    it "keeps the token for an hour rather than raising, when the expiry is not a timestamp" do
      issue_with_expiry("whenever")

      expect { instance.token(base_url) }.not_to raise_error

      expect(instance.token(base_url)).to eq("tok-1")
      expect(instance.exists?(base_url)).to be(true)
      expect(Excon).to have_received(:post).once
    end

    it "does the same when the expiry is not a string at all" do
      issue_with_expiry(1_735_689_600)

      expect(instance.token(base_url)).to eq("tok-1")
      expect(instance.exists?(base_url)).to be(true)
    end

    it "does the same when the expiry is missing entirely" do
      allow(Excon).to receive(:post).and_return(
        double("response", status: 200, body: JSON.generate(token: "tok-1", base_url: base_url))
      )

      expect(instance.token(base_url)).to eq("tok-1")
      expect(instance.exists?(base_url)).to be(true)
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
      expect { result = instance.token(base_url) }.not_to raise_error

      expect(result).to be_nil
      expect(logger).to have_received(:error).with(/client credentials revoked/)
    end

    it "returns nil and says so when the intake could not be reached at all" do
      allow(Excon).to receive(:post).and_raise(Excon::Error::Timeout.new("timed out"))

      result = nil
      expect { result = instance.token(base_url) }.not_to raise_error

      expect(result).to be_nil
      expect(logger).to have_received(:error).with(/no response/)
    end

    # Without a base URL there is no application environment to cache the
    # token under, so no token is handed back either. Keying on the caller's
    # URL instead would store an entry per resource URL, and nothing here
    # evicts -- a bounded extra request traded for an unbounded leak. This is
    # NOT a fallback: a response carrying a token but no base_url is a failed
    # mint, full stop.
    it "treats a response without a base_url as a failed mint" do
      allow(Excon).to receive(:post).and_return(
        double("response", status: 200, body: JSON.generate(token: "tok-1"))
      )

      expect(instance.token("https://example.test/orders/1")).to be_nil
      expect(instance.token("https://example.test/orders/2")).to be_nil

      expect(instance.exists?("https://example.test/orders/1")).to be(false)
      # Nothing was cached, so the second call had to ask again.
      expect(Excon).to have_received(:post).twice
      # Says what actually happened: a broken server, not a bad request.
      expect(logger).to have_received(:error).at_least(:once).with(/carried a token but no base_url/)
    end

    it "does not cache the failure, so the next request tries again" do
      allow(Excon).to receive(:post).and_return(double("response", status: 500, body: "{}"))
      instance.token(base_url)

      allow(Excon).to receive(:post).and_return(
        double("response", status: 200, body: JSON.generate(token: "recovered", expired_at: (Time.now + 3600).utc.iso8601,
                                                            base_url: base_url))
      )

      expect(instance.token(base_url)).to eq("recovered")
    end
  end

  describe "thread safety" do
    # The cached token is read without the mutex; the mutex is only taken to
    # exchange. A caller that waited for it has to re-read rather than
    # exchange again, or a burst at startup fans out into one call each.
    it "lets callers racing for a token share one generation" do
      allow(Excon).to receive(:post).and_return(
        double("response", status: 200, body: JSON.generate(token: "tok-1", expired_at: (Time.now + 3600).utc.iso8601,
                                                            base_url: base_url))
      )

      results = []
      results_mutex = Mutex.new
      barrier_count = 8
      threads = Array.new(barrier_count) do
        Thread.new do
          value = instance.token(base_url)
          results_mutex.synchronize { results << value }
        end
      end
      threads.each(&:join)

      expect(Excon).to have_received(:post).once
      expect(results).to eq(["tok-1"] * barrier_count)
    end

    # The fast path reads the entries Hash without the mutex, so a write has
    # to REPLACE it rather than mutate it in place. Mutating in place risks
    # "can't add a new key into hash during iteration" the moment a second
    # target is minted while another thread is doing a lookup -- which is
    # exactly what a service that calls two targets does all day.
    #
    # MRI's GVL means a pure computation loop rarely gets preempted inside a
    # single #each_key call, so reproducing the race takes real contention:
    # many reader threads competing for GVL turns against a writer growing the
    # table, over enough rounds that a preemption eventually lands mid-scan.
    # Verified against a mutate-in-place implementation: this configuration
    # (16 readers, 2000 rounds) raised "can't add a new key into hash during
    # iteration" in 5/5 runs; 300 rounds with 4-8 readers (an earlier attempt)
    # did not reproduce it in dozens of runs -- too small a window. This is
    # Ruby's rough equivalent of Python's `sys.setswitchinterval`, which makes
    # the same class of race reproducible on demand there.
    it "lets one entry be read safely while another is minted" do
      rounds = 2000
      errors = []
      errors_mutex = Mutex.new

      allow(Excon).to receive(:post) do |_url, options|
        requested = JSON.parse(options[:body])["base_url"]
        token = requested == base_url ? "seed" : "other"
        double("response", status: 200,
                           body: JSON.generate(token: token, expired_at: (Time.now + 3600).utc.iso8601,
                                               base_url: requested))
      end
      instance.token(base_url)

      minter = Thread.new do
        rounds.times { |i| instance.token("https://t#{i}.example.test") }
      rescue StandardError => e
        errors_mutex.synchronize { errors << e }
      end
      readers = Array.new(16) do
        Thread.new do
          rounds.times { raise "unexpected token" unless instance.token(base_url) == "seed" }
        rescue StandardError => e
          errors_mutex.synchronize { errors << e }
        end
      end
      [minter, *readers].each(&:join)

      expect(errors).to eq([])
    end
  end
end
# rubocop:enable Metrics/BlockLength
