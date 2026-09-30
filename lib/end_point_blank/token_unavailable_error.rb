# frozen_string_literal: true

require_relative "target_url"

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
  # `base_url` is the URL the token was wanted for with its userinfo, query
  # and fragment removed ({TargetUrl.strip}), or nil when it could not be
  # parsed. The raw value is never kept: the caller already has it, and a
  # field on an exception reaches error reporting as surely as the message
  # does.
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
      @base_url = TargetUrl.strip(base_url)
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

    UNPARSEABLE_URL = "the requested URL (not shown: it could not be parsed)"
    private_constant :UNPARSEABLE_URL

    # One fixed text per outcome, the same in every EndPointBlank SDK. Never
    # intake's response body (Failure#reason) or an exception message: the
    # message is what reaches logs and error reporting, and neither is ours
    # to vouch for. Failure#reason stays available on #failure.
    def reason
      http = status ? " (HTTP #{status})" : ""

      case outcome
      when :credential_rejected
        "intake rejected this application's client credential#{http}; " \
          "retrying cannot help -- re-issue the credential"
      when :request_rejected
        "intake refused the token request#{http}; check the URL and that a grant covers the target"
      when :server_error
        "intake failed to issue a token#{http}; this may be transient"
      when :transport_error
        "intake could not be reached (timeout, connection refused or retries exhausted); " \
          "this may be transient"
      else
        "the token request failed for an unknown reason"
      end
    end

    def build_message
      "Could not mint an EndPointBlank access token for #{base_url || UNPARSEABLE_URL}: #{reason}. " \
        "EndPointBlank never sends this service's client_id/client_secret to a provider, " \
        "so there is no Basic-auth fallback and the call must not be made without a token."
    end
  end
end
