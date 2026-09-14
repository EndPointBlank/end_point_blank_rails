# frozen_string_literal: true

require "singleton"

module EndPointBlank
  module Commands
    # Thread-safe singleton cache for storing authentication credentials.
    # Capped at MAX_SIZE entries. When full, stale entries are evicted first;
    # if still at capacity the entry expiring soonest is removed.
    #
    # Validity is re-derived on every read against the cache_ttl configured
    # AT READ TIME (sc-755), not just against the expiry computed when the
    # entry was written:
    #
    #   - If cache_ttl is currently disabled (<= 0), every entry MISSes and is
    #     deleted outright the moment it is read (or would be written).
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
          ttl = ::EndPointBlank::Configuration.instance.cache_ttl
          # A disabled cache stores nothing -- there is nothing to make
          # already-stale later, and this keeps "disabled" meaning the same
          # thing whether you are reading or writing.
          next if cache_disabled?(ttl)

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

      # Looks up `key` and, if it is present, applies the current cache_ttl
      # to decide whether it is still valid -- deleting it if not. Must be
      # called with @mutex already held: the delete below removes exactly the
      # entry this method just read (nobody else can have written a fresh one
      # for the same key in between, since every writer holds the same
      # mutex), so a stale delete can never clobber a concurrently-written
      # fresh entry.
      def valid_entry(key)
        entry = @cache[key]
        return nil unless entry

        ttl = ::EndPointBlank::Configuration.instance.cache_ttl
        if cache_disabled?(ttl) || !fresh?(entry, Time.now, ttl)
          @cache.delete(key)
          return nil
        end

        entry
      end

      def cache_disabled?(ttl)
        ttl.nil? || ttl <= 0
      end

      # Evict stale entries first (using the ttl we are about to write with --
      # the same rule a subsequent read would apply); if still at capacity,
      # evict whichever remaining entry expires soonest.
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
