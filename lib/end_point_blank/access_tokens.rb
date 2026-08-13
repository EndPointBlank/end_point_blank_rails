# frozen_string_literal: true

require 'singleton'
require "time"

module EndPointBlank
  # Thread-safe singleton holding this process's access tokens, one per
  # application environment.
  #
  # A token is cached under the canonical base URL intake resolved the
  # request to -- not under the URL the caller supplied. A caller asks for the
  # URL it is about to call; intake answers with the base URL of the
  # environment that URL belongs to, and subsequent calls anywhere under that
  # base URL reuse the entry.
  #
  # Lookup is a plain exact-or-path-prefix comparison, with the longest match
  # winning. The SDK deliberately does not normalize: intake owns that rule,
  # and a miss costs one extra request rather than a wrong answer.
  #
  # A lookup has to scan the keys, and the fast path deliberately does not
  # take the mutex, so every write **replaces** the entries Hash instead of
  # mutating it. A reader then takes one atomic read of @entries and iterates
  # something nobody can change underneath it. Mutating in place would risk
  # "can't add a new key into hash during iteration" as soon as one thread
  # minted a token for a second target while another was doing a lookup.
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
      @entries = {}
    end

    def self.token(base_url)
      instance.token(base_url)
    end

    # Retrieve a token covering base_url, generating one if no usable entry
    # covers it.
    # @param base_url [String] the URL you are about to call, with any query
    #   string and fragment removed. It is sent verbatim; intake normalizes it
    #   and matches it against registered base URLs by longest path prefix.
    # @return [String, nil] The access token string, or nil if generation
    #   failed -- which includes a response that carried a token but no
    #   base_url.
    def token(base_url)
      entry = match(base_url)
      return entry[:token] if usable?(entry)

      @mutex.synchronize do
        # Another caller may have filled it while this one waited.
        entry = match(base_url)
        return entry[:token] if usable?(entry)

        payload = Commands::GenerateAccessToken.token(base_url)

        # The key is what intake resolved to, and only that. There is no
        # fallback to the requested URL: that would key on the resource the
        # caller happened to ask about, so a service walking /orders/1,
        # /orders/2, /orders/3 would mint and store a token per resource, and
        # nothing here evicts. Without a base URL the right application
        # cannot be found, so no token is handed back either.
        key = payload && payload[:base_url]

        if payload && payload[:token] && key
          # The match that led here may have resolved under a different key
          # than the one intake just returned -- an environment's base URL
          # can change to a shorter path in the portal. Drop that stale key
          # when it differs from the fresh one, or it goes on shadowing it:
          # being the longer of the two, it keeps winning "longest match
          # wins", keeps failing usable?, and keeps forcing a mint on every
          # call until the process restarts. The failure branch below already
          # does the equivalent for a match that turned out unusable; this is
          # the same cleanup for a match that turned out to have moved.
          stale = match_key(base_url, @entries)
          new_entries = @entries.merge(
            key => { token: payload[:token], expired_at: parse_expiry(payload[:expired_at]) }.freeze
          )
          new_entries = new_entries.reject { |k, _| k == stale } if stale && stale != key
          @entries = new_entries.freeze
          payload[:token]
        else
          # A failed refresh must not leave an expiring token behind claiming
          # to be usable -- callers would keep presenting it right up to the
          # 401. Only the entry that covers this URL goes: the longest match
          # is the one that was just found unusable, so a shorter, still-good
          # entry survives.
          stale = match_key(base_url, @entries)
          @entries = @entries.reject { |k, _| k == stale }.freeze if stale

          EndPointBlank.logger.error "Failed to generate access token for #{base_url}: #{failure_reason(payload)}"
          nil
        end
      end
    end

    # Discard every held token
    # @return [nil]
    def clear
      @mutex.synchronize { @entries = {}.freeze }
    end

    # Discard the held token, but only if it is still the one the caller had
    #
    # Every request in flight when a token is rejected reports the same stale
    # value. Only the first of them should cause an exchange -- the rest are
    # holding a token that has already been replaced, and clearing on their
    # behalf would discard a good token and stampede intake.
    #
    # The lookup is by token value because a rejected caller has a token, not
    # a URL.
    #
    # @param stale_token [String, nil] the token the caller was rejected for;
    #   ignored when it is no longer the one held for its base URL.
    # @return [nil]
    def invalidate(stale_token)
      return if stale_token.nil?

      @mutex.synchronize do
        @entries = @entries.reject { |_, entry| entry[:token] == stale_token }.freeze
      end
    end

    # Check whether a token covering base_url is held and is not about to
    # expire
    # @param base_url [String] the URL to check coverage for
    # @return [Boolean]
    def exists?(base_url)
      entry = match(base_url)
      !entry.nil? && entry[:expired_at] > Time.now + PRESENCE_WINDOW
    end

    private

    # Returns the longest key in entries covering base_url, or nil.
    #
    # A nil or empty base_url never matches. An empty cache can't raise on
    # one -- the loop body never runs -- so a non-empty cache must not either,
    # or the same call succeeds or raises NoMethodError (nil has no
    # start_with?) depending on unrelated traffic that happened to warm the
    # cache first. Checking once, here, keeps every caller consistent for
    # free: the lookup, the stale-entry cleanup on a failed refresh, and the
    # stale-entry cleanup on a successful one.
    #
    # Deliberately not a port of intake's matcher: no normalization on either
    # side. A caller that passes a non-canonical URL simply misses and mints
    # again, which costs one HTTP call and is never a wrong answer.
    #
    # Takes entries as an explicit argument, rather than reading @entries
    # itself, so the snapshot discipline is structural: every caller decides
    # which snapshot is being scanned instead of this method reaching for
    # whatever @entries happens to be at the moment it runs.
    def match_key(base_url, entries)
      return nil if base_url.nil? || base_url.empty?

      best = nil
      entries.each_key do |key|
        next unless base_url == key || base_url.start_with?("#{key}/")

        best = key if best.nil? || key.length > best.length
      end
      best
    end

    def match(base_url)
      entries = @entries # One atomic read; writes replace, never mutate.
      key = match_key(base_url, entries)
      key && entries[key]
    end

    def usable?(entry)
      !entry.nil? && entry[:expired_at] > Time.now + REFRESH_WINDOW
    end

    # Why a mint produced no usable token, for the log.
    def failure_reason(payload)
      return "no response" unless payload.is_a?(Hash)
      return payload[:error] if payload[:error]

      if payload[:token]
        # Distinct from a rejected request: intake's base_url is NOT NULL, and
        # it answers 422 rather than minting when the caller's URL resolves to
        # no environment. A token with no base_url is a broken server.
        return "response carried a token but no base_url"
      end

      "no token in response"
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
