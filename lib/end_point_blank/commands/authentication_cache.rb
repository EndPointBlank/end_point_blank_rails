# frozen_string_literal: true

require 'singleton'

module EndPointBlank
  module Commands
    # Thread-safe singleton cache for storing authentication credentials
    class AuthenticationCache
      include Singleton

      def initialize
        @cache = {}
        @mutex = Mutex.new
      end

      # Store credentials in the cache
      # @param key [String, Symbol] The identifier for the credentials
      # @param credentials [Object] The credentials to store
      # @return [Object] The stored credentials
      def store(key, credentials)
        @mutex.synchronize do
          @cache[key] = { expired_at: Time.now + ::EndPointBlank::Configuration.instance.cache_ttl, credentials: credentials } if credentials
        end
      end

      # Retrieve credentials from the cache
      # @param key [String, Symbol] The identifier for the credentials
      # @return [Object, nil] The stored credentials or nil if not found
      def retrieve(key)
        @mutex.synchronize do
          if @cache.key?(key)
            @cache[key][:credentials] if @cache[key][:expired_at] > Time.now
          else
            nil
          end
        end
      end

      # Check if credentials exist for a given key
      # @param key [String, Symbol] The identifier to check
      # @return [Boolean] True if credentials exist, false otherwise
      def exists?(key)
        @mutex.synchronize do
          @cache.key?(key) && @cache[key][:expired_at] > Time.now
        end
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
    end
  end
end
