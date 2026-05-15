# frozen_string_literal: true

require 'singleton'

module EndPointBlank
  # Thread-safe singleton cache for storing access tokens per hostname
  class AccessTokens
    include Singleton

    def initialize()
      @tokens = {}
      @mutexes = {}
    end

    def self.token(arg)
      instance.token(arg)
    end

    # Retrieve or generate an access token for the given hostname
    # @param hostname [String] The hostname for which to retrieve the token
    # @return [String, nil] The access token or nil if generation fails
    def token(arg)
      hostname = arg.downcase
      @mutexes[hostname] ||= Mutex.new
      @mutexes[hostname].synchronize do
        # Return cached token if it exists and is not expired
        if @tokens.key?(hostname) && @tokens[hostname][:expired_at] > 2.minutes.from_now
          return @tokens[hostname][:token]
        end

        # Fetch new token
        payload = Commands::GenerateAccessToken.token(hostname)

        if payload && payload[:token]
          payload[:expired_at] = DateTime.parse(payload[:expired_at])
          @tokens[hostname] = payload
          payload[:token]
        else
          ::Rails.logger.error "Failed to generate access token for #{hostname}: #{payload&.fetch('error')}"
          nil
        end
      end
    end

    # Clear all tokens from the cache
    # @return [Hash] Empty hash
    def clear(arg)
      @mutexes.keys.each do |hostname|
        @mutexes[hostname].synchronize do
          @tokens.delete(hostname)
        end
      end
    end

    # Remove token for a specific hostname
    # @param hostname [String] The hostname for which to remove the token
    # @return [Object, nil] The removed token data or nil if not found
    def remove(arg)
      hostname = arg.downcase
      @mutexes[hostname].synchronize do
        @tokens.delete(hostname)
      end
    end

    # Check if a valid token exists for a given hostname
    # @param hostname [String] The hostname to check
    # @return [Boolean] True if a valid token exists, false otherwise
    def exists?(arg)
      hostname = arg.downcase
      @tokens.key?(hostname) && @tokens[hostname][:expired_at] > Time.now + 30
    end
  end
end
