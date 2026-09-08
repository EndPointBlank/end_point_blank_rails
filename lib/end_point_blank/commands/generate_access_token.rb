#!/bin/ruby

require 'excon'
require "json"
require_relative 'http'

module EndPointBlank
  module Commands
    # The outcome of one attempt to mint an access token, with enough of the
    # intake's answer attached that a caller can decide what to do about it.
    #
    # intake's access-token endpoint answers 201 on success, 400 for a bad
    # request (an invalid token_ttl, a missing base_url), 401 for a rejected
    # credential, 422 when the target or source application cannot be resolved
    # or the mint itself failed, and 5xx for a genuine fault. Those are not
    # interchangeable: 401 needs the credential re-issued, 400/422 need the
    # request or the registration fixed, and 5xx or a dead socket just needs
    # trying again. Collapsing them -- which is what returning a bare Hash or
    # nil does -- is what made every failure look the same to a caller.
    #
    # A Data is deeply appropriate here: it is immutable and frozen, so a
    # result can be handed across threads, cached, or logged without anyone
    # being able to edit the verdict after the fact.
    AccessTokenResult = Data.define(:outcome, :status, :payload) do
      # 2xx, carrying a payload there is actually a token to be had from.
      def success?
        outcome == :success
      end

      # 401. Permanent until the API credential itself changes.
      def credential_rejected?
        outcome == :credential_rejected
      end

      # Any other 4xx -- in practice intake's 400 and 422. Permanent too, but
      # the credential is fine; the request or the registration is not.
      def request_rejected?
        outcome == :request_rejected
      end

      # 5xx, any other unexpected non-2xx, and a 2xx that carried nothing
      # usable -- unreadable, or missing the token, or missing the base_url
      # there is no way to cache a token without.
      def server_error?
        outcome == :server_error
      end

      # No answer at all: timeout, refused connection, DNS failure -- any
      # case where no usable HTTP status was obtained. Transient.
      #
      # Note what is NOT here: a body we could not read. That is classified
      # by the status that carried it, because the status is the part with
      # the remedy in it.
      def transport_error?
        outcome == :transport_error
      end

      # The direct complement of #success?, and deliberately the only
      # predicate here that spans more than one outcome. There is no
      # #retriable? on purpose: a single retry/no-retry boolean would fold
      # five honest names back into two, and it is one more thing that can
      # answer wrongly for a 400 or a 422. A caller that wants a retry policy
      # writes it against the outcome it can see.
      def failure?
        !success?
      end
    end

    module GenerateAccessTokenMethods
      module ClassMethods
        def configuration
          EndPointBlank::Configuration.instance
        end

        # Mint an access token, reporting what actually happened.
        #
        # @param base_url [String] the URL a token is wanted for.
        # @return [AccessTokenResult] never nil.
        def token_result(base_url)
          response = post_token_request(base_url)

          status = response.status
          EndPointBlank.logger.info "Authentication response: #{status}"

          # parse_payload never raises, so nothing between here and the
          # classification can throw away a status we already hold.
          payload = parse_payload(response.body)

          # The invariant, enforced in exactly one place: :transport_error
          # means no usable HTTP status was obtained. Anything that is not a
          # real status code leaves here rather than reaching classification,
          # so no other branch has to keep re-deciding what a missing status
          # means. The payload still rides along, because `token` below is
          # published API and has always handed back whatever it could parse.
          return transport_error(payload) unless status.is_a?(Integer)

          AccessTokenResult.new(outcome: outcome_for(status, payload), status: status, payload: payload)
        rescue => e
          # Reached only when there is no status to classify on: the request
          # never completed, or the response object would not yield one.
          EndPointBlank.logger.error "Error occurred during authentication: #{e.message}\n #{e.backtrace.join("\n")}"
          transport_error
        end

        # Mint an access token.
        #
        # Kept exactly as it was, deliberately: this is published API. It
        # answers with the parsed, symbolized body for ANY status it managed
        # to read -- including a 401 or a 422 -- and nil when it could not
        # read one at all. Callers that need to tell those apart want
        # {token_result} instead.
        #
        # @param base_url [String] the URL a token is wanted for.
        # @return [Hash, nil] symbol-keyed response body, or nil.
        def token(base_url)
          token_result(base_url).payload
        end

        private

        def post_token_request(base_url)
          body = {base_url: base_url}
          if configuration.token_ttl
            body[:token_ttl] = configuration.token_ttl
          end
          auth = Authorization.header
          Excon.post(configuration.access_token_url,
            headers: {'Authorization' => auth, 'Content-Type' => 'application/json'},
            body: body.to_json,
            **EndPointBlank::Commands::Http::TIMEOUT_OPTIONS
          )
        end

        def transport_error(payload = nil)
          AccessTokenResult.new(outcome: :transport_error, status: nil, payload: payload)
        end

        # Returns the symbolized body, or nil when it cannot be read. Total:
        # it never raises, deliberately, so that a body it cannot make sense
        # of can never cost us the status that body arrived under.
        #
        # A body we cannot parse is still reported rather than swallowed:
        # before this, one blanket `rescue` turned a JSON::ParserError into
        # the same silent nil as a dead socket. The message keeps its original
        # prefix so any log alerting built on the old line still matches.
        def parse_payload(body)
          parsed = body.is_a?(String) ? JSON.parse(body) : body
          parsed.transform_keys(&:to_sym)
        rescue StandardError => e
          EndPointBlank.logger.error "Error occurred during authentication: #{e.message} (response body was not JSON)"
          nil
        end

        # Classify on the HTTP status FIRST; the body only ever refines the
        # answer, and only for a 2xx.
        #
        # :transport_error means exactly one thing -- no usable HTTP status
        # was obtained -- so it is not reachable from here. Do not
        # reintroduce parse-first classification: a 401 whose body will not
        # parse is still a rejected credential, and filing it under a name
        # that reads as transient invites the forever-retry this exists to
        # end. That is not hypothetical. The SDK
        # reaches intake through Caddy, and any proxy, WAF or ALB in front of
        # the app can answer 401 with an HTML error page intake never
        # generated -- the credential really is rejected and the body really
        # is unparseable, at the same time.
        #
        # The one case the body decides is a 2xx that carried nothing usable:
        # unreadable, or missing the token, or missing the base_url there is
        # no way to cache a token without. That is a broken server, and it is
        # truthful to say so with the real 2xx status attached -- intake's
        # base_url is NOT NULL and it answers 422 rather than minting when the
        # URL resolves to nothing, so a 2xx without one cannot be anything
        # else. The specific reason survives in the log line.
        def outcome_for(status, payload)
          case status
          when 200..299 then usable?(payload) ? :success : :server_error
          when 401 then :credential_rejected
          when 400..499 then :request_rejected
          else :server_error # 5xx, and any 3xx, which Excon does not follow.
          end
        end

        def usable?(payload)
          payload.is_a?(Hash) && payload[:token] && payload[:base_url] ? true : false
        end
      end

      def self.included(base)
        base.extend(ClassMethods)
      end
    end

    # Generates an access token by sending a request to a remote authorization service.
    # Returns the access token from the authorization service or nil if an error occurs.
    class GenerateAccessToken
      include GenerateAccessTokenMethods
    end
  end
end
