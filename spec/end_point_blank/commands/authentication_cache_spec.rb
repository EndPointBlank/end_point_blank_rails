# frozen_string_literal: true

require "spec_helper"

RSpec.describe EndPointBlank::Commands::AuthenticationCache do
  let(:cache) { described_class.instance }
  let(:configuration) { EndPointBlank::Configuration.instance }

  around do |example|
    original_ttl = configuration.cache_ttl
    cache.clear

    example.run

    configuration.cache_ttl = original_ttl
    cache.clear
  end

  describe "storing and reading back" do
    it "returns what was stored" do
      cache.store("k", "credentials")

      expect(cache.retrieve("k")).to eq("credentials")
    end

    it "returns nil for a key that was never stored" do
      expect(cache.retrieve("missing")).to be_nil
    end

    it "reports whether a key is present" do
      cache.store("k", "credentials")

      expect(cache.exists?("k")).to be(true)
      expect(cache.exists?("other")).to be(false)
    end

    it "overwrites an existing entry rather than accumulating duplicates" do
      cache.store("k", "first")
      cache.store("k", "second")

      expect(cache.retrieve("k")).to eq("second")
      expect(cache.size).to eq(1)
    end

    # A nil result means the lookup failed, not that the answer is "no".
    # Storing it would pin a transient failure for the whole TTL.
    it "refuses to store a nil value" do
      cache.store("k", nil)

      expect(cache.exists?("k")).to be(false)
      expect(cache.size).to eq(0)
    end

    it "reports the keys it is holding" do
      cache.store("a", 1)
      cache.store("b", 2)

      expect(cache.keys).to contain_exactly("a", "b")
    end

    it "hands out a copy of the keys, so a caller cannot mutate the cache through it" do
      cache.store("a", 1)

      cache.keys << "b"

      expect(cache.keys).to eq(["a"])
    end
  end

  describe "expiry" do
    it "stops serving an entry once its TTL has passed" do
      configuration.cache_ttl = -1
      cache.store("k", "credentials")

      expect(cache.retrieve("k")).to be_nil
      expect(cache.exists?("k")).to be(false)
    end

    it "makes room for new entries by dropping expired ones first" do
      configuration.cache_ttl = -1
      cache.store("stale", "old")
      configuration.cache_ttl = 300
      cache.store("fresh", "new")

      expect(cache.keys).to eq(["fresh"])
    end
  end

  describe "runtime cache_ttl changes (sc-755)" do
    # Every case here re-evaluates validity against the cache_ttl configured
    # AT READ TIME, anchored to when the entry was written -- never by
    # comparing the entry's original expiry against the new ttl (that clamp
    # arithmetic is the bug: an old entry's remaining-till-original-expiry can
    # coincidentally fall under a new, shorter window and look valid again).

    it "(a) shrinks an already-cached entry's life when ttl is lowered, once the new window elapses" do
      t0 = Time.now
      allow(Time).to receive(:now).and_return(t0)
      configuration.cache_ttl = 300
      cache.store("k", "credentials")

      configuration.cache_ttl = 10
      allow(Time).to receive(:now).and_return(t0 + 11)

      expect(cache.retrieve("k")).to be_nil
      expect(cache.exists?("k")).to be(false)
    end

    it "(b) MISSes even though the original (unlowered) expiry has not yet passed -- the clamp case" do
      t0 = Time.now
      allow(Time).to receive(:now).and_return(t0)
      configuration.cache_ttl = 300
      cache.store("k", "credentials")

      configuration.cache_ttl = 10
      # Only 5s "remaining" until the original 300s expiry -- a naive
      # `remaining <= current_ttl` clamp would wrongly call this a HIT.
      allow(Time).to receive(:now).and_return(t0 + 295)

      expect(cache.retrieve("k")).to be_nil
    end

    it "(c) never extends an entry's life when ttl is raised after it was written" do
      t0 = Time.now
      allow(Time).to receive(:now).and_return(t0)
      configuration.cache_ttl = 10
      cache.store("k", "credentials")

      configuration.cache_ttl = 300
      allow(Time).to receive(:now).and_return(t0 + 11)

      expect(cache.retrieve("k")).to be_nil
    end

    it "(d) disabling actually removes the entry, and re-enabling does not resurrect it" do
      configuration.cache_ttl = 300
      cache.store("k", "credentials")

      configuration.cache_ttl = -1
      expect(cache.retrieve("k")).to be_nil
      expect(cache.size).to eq(0)

      configuration.cache_ttl = 300
      expect(cache.retrieve("k")).to be_nil
    end

    it "(e) still HITs when ttl is unchanged and the entry is within window" do
      t0 = Time.now
      allow(Time).to receive(:now).and_return(t0)
      configuration.cache_ttl = 300
      cache.store("k", "credentials")

      allow(Time).to receive(:now).and_return(t0 + 5)

      expect(cache.retrieve("k")).to eq("credentials")
    end
  end

  describe "removing" do
    it "forgets a single entry" do
      cache.store("a", 1)
      cache.store("b", 2)

      cache.remove("a")

      expect(cache.retrieve("a")).to be_nil
      expect(cache.retrieve("b")).to eq(2)
    end

    it "forgets everything on clear" do
      cache.store("a", 1)
      cache.store("b", 2)

      cache.clear

      expect(cache.size).to eq(0)
    end
  end

  describe "the capacity bound" do
    # Unbounded, this cache grows with the number of distinct callers times
    # routes times versions -- an authorization cache is exactly the thing that
    # quietly consumes a host application's memory until it is OOM-killed.
    it "never grows past MAX_SIZE" do
      (described_class::MAX_SIZE + 10).times { |i| cache.store("key-#{i}", i) }

      expect(cache.size).to eq(described_class::MAX_SIZE)
    end

    it "evicts the entry that expires soonest when it is full" do
      configuration.cache_ttl = 300
      cache.store("expires-first", "old")
      configuration.cache_ttl = 600
      (described_class::MAX_SIZE - 1).times { |i| cache.store("key-#{i}", i) }

      cache.store("newcomer", "new")

      expect(cache.exists?("expires-first")).to be(false)
      expect(cache.retrieve("newcomer")).to eq("new")
    end
  end
end
