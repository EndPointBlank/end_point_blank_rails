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
    # Storing with a disabled (<= 0) ttl inserts nothing (sc-755 rule 4), so
    # these two need a genuinely positive ttl and an advanced clock -- with
    # ttl -1, `store` never wrote an entry and both tests below passed
    # without exercising anything.
    it "stops serving an entry once its TTL has passed" do
      t0 = Time.now
      allow(Time).to receive(:now).and_return(t0)
      configuration.cache_ttl = 5
      cache.store("k", "credentials")

      allow(Time).to receive(:now).and_return(t0 + 6)

      expect(cache.retrieve("k")).to be_nil
      expect(cache.exists?("k")).to be(false)
    end

    it "makes room for new entries by dropping entries that are stale under the CURRENT ttl first" do
      t0 = Time.now
      allow(Time).to receive(:now).and_return(t0)
      configuration.cache_ttl = 300
      cache.store("stale", "old")

      # Lower the ttl and move past it: "stale" is now stale even though its
      # own original (300s) expires_at is nowhere close -- so a capacity
      # eviction driven only by "which expires_at is earliest" would never
      # pick it, and would sacrifice a genuinely fresh entry instead. The
      # store-time sweep has to re-check staleness against the current ttl,
      # the same way a read would, not just skip already-expired entries.
      configuration.cache_ttl = 10
      allow(Time).to receive(:now).and_return(t0 + 11)
      (described_class::MAX_SIZE - 1).times { |i| cache.store("key-#{i}", i) }

      cache.store("newcomer", "new")

      expect(cache.keys).not_to include("stale")
      expect(cache.size).to eq(described_class::MAX_SIZE)
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

    # sc-755 rule 1 was amended 2026-09-14 (after js#50 review): a disabled
    # read or store must clear the ENTIRE cache, not just the key it looked
    # up or was about to write. A per-key-only delete let key B keep
    # answering after `configure(0)` -> read A -> `configure(300)`, i.e. a
    # revoked grant could resurrect. This matches Elixir sc-660's
    # AuthCache.clear/0, which clears the whole table on the disabled
    # get/put path. Known, documented residual: a disable -> re-enable with
    # NO cache read or store in between flushes nothing, because nothing
    # observes the disabled state to trigger the clear.
    it "(d2) a disabled read of one key also clears every OTHER cached key, not just the one read" do
      configuration.cache_ttl = 300
      cache.store("a", "a-value")
      cache.store("b", "b-value")

      configuration.cache_ttl = -1
      expect(cache.retrieve("a")).to be_nil
      expect(cache.size).to eq(0)

      configuration.cache_ttl = 300
      expect(cache.retrieve("b")).to be_nil
    end

    it "a disabled read of a key that was never cached still clears everything else" do
      configuration.cache_ttl = 300
      cache.store("a", "a-value")
      cache.store("b", "b-value")

      configuration.cache_ttl = -1
      expect(cache.retrieve("never-stored")).to be_nil
      expect(cache.size).to eq(0)

      configuration.cache_ttl = 300
      expect(cache.retrieve("b")).to be_nil
    end

    it "a store that observes the cache disabled clears everything already cached, and stores nothing itself" do
      configuration.cache_ttl = 300
      cache.store("a", "a-value")
      cache.store("b", "b-value")

      configuration.cache_ttl = -1
      cache.store("c", "c-value")

      expect(cache.size).to eq(0)
      expect(cache.exists?("c")).to be(false)

      configuration.cache_ttl = 300
      expect(cache.retrieve("b")).to be_nil
    end

    it "physically deletes a stale entry on an ordinary enabled read, not merely hides it" do
      t0 = Time.now
      allow(Time).to receive(:now).and_return(t0)
      configuration.cache_ttl = 300
      cache.store("k", "credentials")
      cache.store("other", "value")

      configuration.cache_ttl = 10
      allow(Time).to receive(:now).and_return(t0 + 11)

      expect(cache.retrieve("k")).to be_nil
      expect(cache.keys).to eq(["other"])
      expect(cache.size).to eq(1)
    end

    it "exists? applies the current ttl itself, not just what a prior retrieve already deleted" do
      t0 = Time.now
      allow(Time).to receive(:now).and_return(t0)
      configuration.cache_ttl = 300
      cache.store("k", "credentials")

      configuration.cache_ttl = 10
      allow(Time).to receive(:now).and_return(t0 + 11)

      expect(cache.exists?("k")).to be(false)
    end
  end

  describe "a nil cache_ttl" do
    # The controller's ruling: this story must not silently change nil
    # semantics. On master, a nil cache_ttl already failed loudly (a
    # TypeError from `Time.now + nil` inside store). It must keep failing
    # loudly and say so explicitly -- not be read as "disabled" now that
    # every read, not just store, consults cache_ttl. Cross-SDK nil parity
    # (JS/Java/Elixir default a nil ttl rather than raising) is a separate
    # follow-up story; this SDK does not change its nil behavior here.
    it "raises naming cache_ttl, rather than silently disabling the cache, on a store" do
      configuration.cache_ttl = nil

      expect { cache.store("k", "credentials") }.to raise_error(TypeError, /cache_ttl/)
    end

    it "raises naming cache_ttl, rather than silently disabling the cache, on a read" do
      configuration.cache_ttl = 300
      cache.store("k", "credentials")

      configuration.cache_ttl = nil

      expect { cache.retrieve("k") }.to raise_error(TypeError, /cache_ttl/)
      expect { cache.exists?("k") }.to raise_error(TypeError, /cache_ttl/)
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
