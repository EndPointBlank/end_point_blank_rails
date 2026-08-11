# frozen_string_literal: true

require 'singleton'
require "time"

module EndPointBlank
  # Holds this process's access token.
  #
  # The intake issues a token against the application environment that the
  # authenticating credential belongs to. The hostname sent with a generation
  # request only resolves the target server-side; it is not what the token is
  # scoped to. A process authenticates as exactly one application environment,
  # so it needs exactly one token, whatever hostnames its callers address it by.
  class AccessTokens
    include Singleton

    # Replace a token this far ahead of its expiry. An expired token can never
    # be revived, only replaced, so going early is what keeps an in-flight
    # request from carrying one that dies before it lands.
    REFRESH_WINDOW = 120

    # exists? is used to decide whether a caller can proceed without a round
    # trip, so it answers no while there is barely any life left.
    PRESENCE_WINDOW = 30

    # How long to hold a token whose expiry the intake sent unreadably.
    DEFAULT_LIFETIME = 3600

    def initialize
      @mutex = Mutex.new
      @entry = nil
    end

    def self.token(arg)
      instance.token(arg)
    end

    # Retrieve the token, generating one if none is held or it is near expiry
    # @param hostname [String] the hostname to send with a generation request.
    #   It tells the intake which application environment to resolve and does
    #   not select which cached token comes back -- every caller shares one.
    # @return [String, nil] The access token or nil if generation fails
    def token(hostname)
      current = @entry
      return current[:token] if usable?(current)

      @mutex.synchronize do
        # Another caller may have replaced it while this one waited.
        current = @entry
        return current[:token] if usable?(current)

        payload = Commands::GenerateAccessToken.token(hostname)

        if payload && payload[:token]
          @entry = { token: payload[:token], expired_at: parse_expiry(payload[:expired_at]) }.freeze
          @entry[:token]
        else
          # Discard whatever is held rather than leaving it behind. Only a token
          # already inside the refresh buffer reaches an exchange, so what would
          # be kept is close to death — and exists?, whose floor is 30 seconds,
          # would go on calling it usable right up to the 401 it is about to earn.
          @entry = nil

          # Hash#fetch raises on a missing key, so the old `payload&.fetch('error')`
          # turned a handled token failure into a KeyError — a 500 raised by the
          # logging of an error, on the path that exists to fail gracefully.
          # It also read a string key while the rest of this method uses symbols,
          # which made the miss near-certain.
          reason =
            if payload.is_a?(Hash)
              payload[:error] || payload["error"] || "no token in response"
            else
              "no response"
            end

          EndPointBlank.logger.error "Failed to generate access token for #{hostname}: #{reason}"
          nil
        end
      end
    end

    # Discard the held token
    # @return [nil]
    def clear
      @mutex.synchronize { @entry = nil }
    end

    # Discard the held token, but only if it is still the one the caller had
    #
    # Every request in flight when a token is rejected reports the same stale
    # value. Only the first of them should cause an exchange -- the rest are
    # holding a token that has already been replaced, and clearing on their
    # behalf would discard a good token and stampede the intake.
    #
    # @param stale_token [String, nil] the token the caller was rejected for;
    #   ignored when it is not the one currently held
    # @return [nil]
    def invalidate(stale_token)
      return if stale_token.nil?

      @mutex.synchronize do
        @entry = nil if @entry && @entry[:token] == stale_token
      end
    end

    # Check whether a token is held and is not about to expire
    # @return [Boolean]
    def exists?
      entry = @entry
      !entry.nil? && entry[:expired_at] > Time.now + PRESENCE_WINDOW
    end

    private

    def usable?(entry)
      !entry.nil? && entry[:expired_at] > Time.now + REFRESH_WINDOW
    end

    # Time.parse raises on anything it cannot read — an ArgumentError for a
    # string it fails to understand, a TypeError for a value that is not a
    # string at all, including the nil left by a missing key. This runs inside
    # the mutex on the path a caller's request goes through, so a malformed
    # timestamp from the intake came out of Authorization.header and into the
    # host application's request.
    #
    # An hour is a guess, but a working one. Treating the token as unusable
    # instead would mean an exchange on every inbound request for as long as
    # the far end misbehaves, and if the token really does die sooner, the 401
    # retry invalidates it and mints another.
    def parse_expiry(value)
      Time.parse(value.to_s)
    rescue ArgumentError, TypeError
      Time.now + DEFAULT_LIFETIME
    end
  end
end
