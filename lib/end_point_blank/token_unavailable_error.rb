# frozen_string_literal: true

require "uri"

module EndPointBlank
  # Reopened with the same superclass in end_point_blank.rb; declared here too
  # so this file can be required on its own.
  class Error < StandardError; end

  # Raised by {Authorization.header} when no access token can be obtained for
  # an outbound call to a provider.
  #
  # There is deliberately no fallback. Before sc-1469 a failed mint silently
  # produced "Basic base64(client_id:client_secret)" instead, which sent this
  # service's own credential to whichever provider it was calling (and to
  # that provider's intake). A client must never do that, so the call cannot
  # be authorized and the caller has to decide what to do: retry, degrade, or
  # fail its own request.
  #
  # `failure` is the {AccessTokens::Failure} recorded for the mint, when one
  # was recorded, so a handler can branch on `failure.outcome`
  # (:credential_rejected, :request_rejected, :server_error,
  # :transport_error) exactly as it would after calling
  # {AccessTokens.last_failure} itself.
  class TokenUnavailableError < Error
    attr_reader :base_url, :failure

    # @param base_url [String] the URL the token was wanted for
    # @param failure [AccessTokens::Failure, nil] why the mint failed
    def initialize(base_url, failure = nil)
      @base_url = base_url
      @failure = failure
      super(build_message)
    end

    # @return [Symbol, nil] the failure outcome, or nil when none was recorded
    def outcome
      failure&.outcome
    end

    # @return [Integer, nil] intake's HTTP status, or nil when it never answered
    def status
      failure&.status
    end

    private

    # Scheme, host and path only. The caller controls base_url, and its
    # userinfo, query or fragment can carry a secret; the message is what
    # reaches logs and error reporting, so they are dropped here. The raw
    # value stays on #base_url.
    def describe_url
      uri = URI.parse(base_url.to_s)
      return UNPARSEABLE_URL unless uri.scheme && uri.host && !uri.host.empty?

      port = uri.port && uri.port != uri.default_port ? ":#{uri.port}" : ""
      "#{uri.scheme}://#{uri.host}#{port}#{uri.path}"
    rescue URI::Error
      UNPARSEABLE_URL
    end

    UNPARSEABLE_URL = "the requested URL (not shown: it could not be parsed)"
    private_constant :UNPARSEABLE_URL

    def build_message
      why =
        if failure
          detail = failure.status ? "HTTP #{failure.status}, " : ""
          "#{failure.outcome}: #{detail}#{failure.reason}"
        else
          "no reason was recorded"
        end

      "Could not mint an EndPointBlank access token for #{describe_url}: #{why}. " \
        "EndPointBlank never sends this service's client_id/client_secret to a provider, " \
        "so there is no Basic-auth fallback and the call must not be made without a token."
    end
  end
end
