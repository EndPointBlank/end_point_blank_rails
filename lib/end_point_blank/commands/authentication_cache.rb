# frozen_string_literal: true

require "singleton"

module EndPointBlank
  module Commands
    # Thread-safe singleton cache for storing authentication credentials.
    # It is scoped to a single Ruby process: there is nothing behind it but
    # a plain Hash (no Rails.cache, Redis, or other shared store), so a
    # Puma or Unicorn worker, and every separate app instance, each hold
    # their own cache and their own view of cache_ttl. Nothing described
    # below crosses a process boundary.
    #
    # Capped at MAX_SIZE entries. When full, stale entries are evicted first;
    # if still at capacity, whichever remaining entry's recorded expires_at
    # is earliest is removed (see the note on make_room_for below -- that is
    # a heuristic, not exactly "closest to becoming stale").
    #
    # Validity is re-derived on every read against the cache_ttl configured
    # AT READ TIME (sc-755), not just against the expiry computed when the
    # entry was written:
    #
    #   - If cache_ttl is currently 0 (disabled), the ENTIRE cache **in
    #     this process** is cleared -- every entry, not just the one looked
    #     up or being stored -- on both a read and a store that observe the
    #     disabled state. (Amended 2026-09-14: an earlier version of this
    #     cache deleted only the single key being read, which let a
    #     *different* key go on answering after cache_ttl was raised again
    #     -- a revoked grant could resurrect. This matches the Elixir SDK's
    #     sc-660 `AuthCache.clear/0`, which clears the whole ETS table on
    #     the disabled get/put path.)
    #     Because each process's cache is independent, this does not reach
    #     any other worker or instance: each one clears only when it has
    #     itself observed cache_ttl disabled and then handled an Authorized
    #     request (or a direct cache call) while disabled. A worker sitting
    #     idle, or one that has not yet picked up the new config, keeps
    #     serving whatever it already cached until it does -- nothing here
    #     coordinates that across processes, and there is no fleet-wide
    #     schedule for when, or whether, any given process's turn comes.
    #     Known residual, left unaddressed here rather than fixed: a disable
    #     followed by a re-enable with **no cache read or store in between**
    #     flushes nothing, because nothing ever observed the disabled state
    #     to trigger the clear. This story does not add configure-time
    #     flushing.
    #   - Otherwise an entry HITs only while it is within BOTH its original
    #     write-time expiry (so raising cache_ttl later never extends an
    #     entry's life) AND the CURRENT cache_ttl measured from its write
    #     time (so lowering cache_ttl shortens already-cached entries on
    #     their next read, without waiting for the original expiry).
    #
    # This is deliberately not "remaining time until the original expiry <=
    # the new ttl" -- that arithmetic drifts back into looking valid once
    # enough real time has passed, even though the entry is older than the
    # new ttl allows. Elapsed-since-write is compared to the current ttl
    # directly instead.
    #
    # cache_ttl is always a non-negative Integer by the time this cache reads
    # it: Configuration#cache_ttl= refuses nil, negative numbers and
    # non-Integers at configure time (sc-970), so there is no invalid value
    # left for this class to detect at read or store time. Until sc-970 a
    # nil was only caught here, at the first cache use; that check moved
    # into the setter rather than being duplicated.
    class AuthenticationCache
      include Singleton

      MAX_SIZE = 1000

      def initialize
        @cache = {}
        @mutex = Mutex.new
      end

      # Store credentials in the cache
      # @param key [String, Symbol] The identifier for the credentials
      # @param credentials [Object] The credentials to store
      # @return [Object] The stored credentials
      def store(key, credentials)
        return unless credentials

        @mutex.synchronize do
          ttl = current_ttl
          # A store made while disabled clears whatever is already cached,
          # same as a disabled read -- see the class comment -- and inserts
          # nothing itself.
          next if clear_if_disabled!(ttl)

          now = Time.now
          make_room_for(now, ttl)
          @cache[key] = { written_at: now, expires_at: now + ttl, credentials: credentials }
        end
      end

      # Retrieve credentials from the cache
      # @param key [String, Symbol] The identifier for the credentials
      # @return [Object, nil] The stored credentials or nil if not found
      def retrieve(key)
        @mutex.synchronize do
          entry = valid_entry(key)
          entry && entry[:credentials]
        end
      end

      # Check if credentials exist for a given key
      # @param key [String, Symbol] The identifier to check
      # @return [Boolean] True if credentials exist, false otherwise
      def exists?(key)
        @mutex.synchronize { !valid_entry(key).nil? }
      end

      # Remove credentials from the cache
      # @param key [String, Symbol] The identifier for the credentials to remove
      # @return [Object, nil] The removed credentials or nil if not found
      def remove(key)
        @mutex.synchronize do
          @cache.delete(key)
        end
      end

      # Clear all credentials from the cache
      # @return [Hash] Empty hash
      def clear
        @mutex.synchronize do
          @cache.clear
        end
      end

      # Get all keys in the cache
      # @return [Array] Array of all keys
      def keys
        @mutex.synchronize do
          @cache.keys.dup
        end
      end

      # Get the number of credentials stored
      # @return [Integer] The size of the cache
      def size
        @mutex.synchronize do
          @cache.size
        end
      end

      private

      # Looks up `key` against the CURRENT cache_ttl.
      #
      # If the cache is disabled, the entire cache is cleared -- see the
      # class comment -- and this returns nil regardless of whether `key`
      # was ever present (a disabled read of a key that was never cached
      # still has to flush everything else).
      #
      # Otherwise, if `key` is present but stale under the current ttl, only
      # that single entry is deleted. Must be called with @mutex already
      # held: every delete here runs in the same critical section as the
      # read that decided it was stale, so a concurrently-written fresh
      # entry for the same key can never be the one removed.
      def valid_entry(key)
        ttl = current_ttl
        return nil if clear_if_disabled!(ttl)

        entry = @cache[key]
        return nil unless entry

        if fresh?(entry, Time.now, ttl)
          entry
        else
          @cache.delete(key)
          nil
        end
      end

      # Already validated by Configuration#cache_ttl= -- see the class
      # comment.
      def current_ttl
        ::EndPointBlank::Configuration.instance.cache_ttl
      end

      def cache_disabled?(ttl)
        ttl <= 0
      end

      # If `ttl` means disabled, clears the whole cache and returns true;
      # otherwise returns false and leaves the cache untouched. Shared by
      # the read and write paths so "disabled" clears everything identically
      # from either one -- see the class comment.
      def clear_if_disabled!(ttl)
        return false unless cache_disabled?(ttl)

        @cache.clear
        true
      end

      # Evict stale entries first (using the ttl we are about to write with
      # -- the same rule a subsequent read would apply); if still at
      # capacity, evict whichever remaining entry's recorded expires_at is
      # earliest. That is a heuristic, not the true "closest to becoming
      # stale under the current ttl" (which would be
      # min(expires_at, written_at + ttl)) -- harmless today since it only
      # ever picks among entries `fresh?` already accepted, but not the same
      # claim as "expires soonest".
      def make_room_for(now, ttl)
        @cache.delete_if { |_, v| !fresh?(v, now, ttl) }
        return if @cache.size < MAX_SIZE

        oldest_key = @cache.min_by { |_, v| v[:expires_at] }.first
        @cache.delete(oldest_key)
      end

      # An entry is fresh only while it is within BOTH its own write-time
      # expiry (raising ttl later never extends it) AND the currently
      # configured ttl measured from when it was written (lowering ttl
      # shortens it immediately). Never compare remaining-time-to-expiry
      # against the new ttl -- see the class comment.
      def fresh?(entry, now, ttl)
        now < entry[:expires_at] && (now - entry[:written_at]) < ttl
      end
    end
  end
end
