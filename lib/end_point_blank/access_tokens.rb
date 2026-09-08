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

    # How many distinct base URLs to remember a failure for.
    #
    # DO NOT REMOVE THIS BOUND. A failure record is cleared only by a
    # SUCCESSFUL mint, and the headline failure this whole class now
    # distinguishes -- a revoked credential -- is precisely the case where a
    # successful mint never comes. Every call fails, forever, so a service
    # walking /orders/1, /orders/2, /orders/3 would record one entry per
    # resource URL and clear none of them: an unbounded leak inside a gem
    # embedded in someone else's long-lived process. It is the same trap the
    # token cache avoids by keying on the environment intake resolves to
    # rather than on the caller's URL (see the class comment), and the
    # failure path must not reintroduce it.
    #
    # The cap is enforced on INSERT, not only on a successful mint, for the
    # same reason. Hashes are insertion-ordered, so the oldest record is the
    # one that goes. A caller only ever asks about a URL it just called, so
    # a bound this size is never in practice the reason an answer is missing.
    MAX_FAILURES = 64

    # Why the last mint for a base URL did not produce a token.
    #
    # Immutable and frozen (a Data), so it can be published straight out of
    # {AccessTokens#last_failure} without a copy and without any chance of a
    # caller editing the record the cache is holding.
    Failure = Data.define(:base_url, :outcome, :status, :reason, :at) do
      # 401. Permanent until the API credential itself is re-issued.
      def credential_rejected?
        outcome == :credential_rejected
      end

      # Any other 4xx -- intake's 400 and 422. Permanent, but the credential
      # is fine: the request or the environment registration is not.
      def request_rejected?
        outcome == :request_rejected
      end

      # 5xx, any other unexpected non-2xx, and a 2xx that carried nothing the
      # cache could use (no token, or no base_url to key one under).
      def server_error?
        outcome == :server_error
      end

      # No usable HTTP status was obtained at all: timeout, refused
      # connection, DNS failure. Note what is NOT here -- a body that would
      # not parse is classified by the status that carried it.
      def transport_error?
        outcome == :transport_error
      end
    end

    def initialize
      @mutex = Mutex.new
      @entries = {}
      @failures = {}
    end

    def self.token(base_url)
      instance.token(base_url)
    end

    def self.last_failure(base_url)
      instance.last_failure(base_url)
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

        result = Commands::GenerateAccessToken.token_result(base_url)
        payload = result.payload

        # The key is what intake resolved to, and only that. There is no
        # fallback to the requested URL: that would key on the resource the
        # caller happened to ask about, so a service walking /orders/1,
        # /orders/2, /orders/3 would mint and store a token per resource, and
        # nothing here evicts. Without a base URL the right application
        # cannot be found, so no token is handed back either.
        key = payload && payload[:base_url]

        # `result.success?` is new: previously any response carrying a token
        # and a base_url was cached, whatever status it arrived under. Only a
        # 2xx mints a usable token, and a 4xx that happened to echo one back
        # is a broken server, not a credential.
        # success? already means "a 2xx carrying both a token and a base_url",
        # so key and payload[:token] are guaranteed here rather than tested.
        # A 2xx missing either is reported as a server error and falls to the
        # branch below, exactly as a 500 would.
        if result.success?
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
          clear_failure(base_url, key)
          payload[:token]
        else
          # A failed refresh must not leave an expiring token behind claiming
          # to be usable -- callers would keep presenting it right up to the
          # 401. Only the entry that covers this URL goes: the longest match
          # is the one that was just found unusable, so a shorter, still-good
          # entry survives.
          stale = match_key(base_url, @entries)
          @entries = @entries.reject { |k, _| k == stale }.freeze if stale

          record_failure(base_url, result)
          nil
        end
      end
    end

    # Why the last attempt to mint a token for base_url failed, or nil if the
    # last attempt succeeded -- or if there has never been one.
    #
    # Additive: nothing else changed shape for this. `token` still answers
    # with a token String or nil, so an existing caller sees no difference;
    # one that wants to know whether to give up or try again asks here.
    #
    # Scope: one record per base URL, keyed on the URL as it was passed to
    # `token` rather than on whatever intake resolved it to -- a failed mint
    # often has no resolved base URL to speak of, and the caller has only the
    # URL it asked with. The map is bounded; see MAX_FAILURES.
    #
    # Reads @failures exactly the way `match` reads @entries: one atomic read
    # of the ivar, no mutex, and every write inside the mutex REPLACES the
    # Hash rather than mutating it. A reader therefore iterates (or here,
    # indexes) a snapshot nobody can change underneath it, and can never see
    # a half-built map. Being a frozen Data, the Failure handed back needs no
    # defensive copy.
    #
    # @param base_url [String] the URL that was asked about
    # @return [Failure, nil]
    def last_failure(base_url)
      @failures[base_url]
    end

    # How many failure records are held. Exposed so the MAX_FAILURES bound is
    # testable without reaching into the ivars.
    # @return [Integer]
    def failure_count
      @failures.size
    end

    # Discard every held token, and every record of why one could not be held
    # @return [nil]
    def clear
      @mutex.synchronize do
        @entries = {}.freeze
        @failures = {}.freeze
      end
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

    # Log the failure and remember it. Runs inside the mutex.
    #
    # The 401 gets its own line, and it is loud: it is the one failure that
    # will not clear on its own, and the one whose remedy is a human action.
    # Folding it into the generic line -- which is what happened before -- let
    # a revoked credential scroll past looking exactly like a blip.
    def record_failure(base_url, result)
      reason = failure_reason(result)

      if result.credential_rejected?
        EndPointBlank.logger.error(
          "ACCESS TOKEN CREDENTIAL REJECTED for #{base_url}: intake answered 401 (#{reason}). " \
          "This will not recover by retrying -- re-issue the API credential and update " \
          "client_id/client_secret."
        )
      else
        EndPointBlank.logger.error "Failed to generate access token for #{base_url}: #{reason}"
      end

      failures = @failures.reject { |k, _| k == base_url }
      # Bounded on insert, oldest evicted first -- see MAX_FAILURES for why
      # this cannot be left to the clear-on-success path. Hash#shift removes
      # the oldest insertion, and `failures` is a fresh copy no other thread
      # can see yet, so mutating it here is safe; only the finished, frozen
      # Hash is published to @failures.
      failures.shift while failures.size >= MAX_FAILURES
      @failures = failures.merge(
        base_url => Failure.new(base_url: base_url, outcome: result.outcome, status: result.status,
                                reason: reason, at: Time.now)
      ).freeze
    end

    # A success wipes the record, so `last_failure` never reports a problem
    # that has already resolved itself. Both keys go: the URL the caller
    # asked with, and the canonical one intake resolved it to, which a later
    # call may well ask about instead. Runs inside the mutex, and replaces
    # rather than mutates, like every other write here.
    def clear_failure(base_url, key)
      return if @failures.empty?

      @failures = @failures.reject { |k, _| k == base_url || k == key }.freeze
    end

    # Why a mint produced no usable token, in words, for the log and for
    # {Failure#reason}.
    def failure_reason(result)
      payload = result.payload

      return "no response" if result.transport_error?
      return payload[:error] if payload.is_a?(Hash) && payload[:error]
      return "unreadable response body (HTTP #{result.status})" if payload.nil?

      # A 2xx is classified as a server error when it carried nothing usable,
      # so the outcome alone does not say which way it was useless. Say it
      # here: this is the only place the distinction still exists.
      if (200..299).cover?(result.status)
        # Distinct from a rejected request: intake's base_url is NOT NULL, and
        # it answers 422 rather than minting when the caller's URL resolves to
        # no environment. A token with no base_url is a broken server.
        return "response carried a token but no base_url" if payload[:token]

        return "no token in response"
      end

      "HTTP #{result.status}"
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
    # the far end misbehaves. There is no retry here if the token dies sooner
    # than the guess -- invalidate has no caller on this path -- so a bad
    # guess means 401s until the cache's own expiry-based refresh catches up.
    def parse_expiry(value)
      Time.parse(value.to_s)
    rescue ArgumentError, TypeError
      Time.now + DEFAULT_LIFETIME
    end
  end
end
