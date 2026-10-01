#!/bin/ruby

require 'base64'
require_relative 'token_unavailable_error'
require_relative 'configuration_error'
require_relative 'target_url'

module EndPointBlank
  module AuthorizationMethods
    module ClassMethods
      def configuration
        EndPointBlank::Configuration.instance
      end

      # Builds the Authorization header for an outbound call to a provider.
      #
      # Always a Bearer token, never this service's own credentials: a client
      # must never send its client_id/client_secret to a provider or to the
      # provider's intake (sc-1469). When no token can be obtained -- the mint
      # was rejected (401, 400/422), intake failed (5xx), or it could not be
      # reached at all (timeout, refused connection) -- this raises rather
      # than falling back to Basic.
      #
      # @param base_url [String] the URL you are about to call. A token
      #   covering it is used, minting one if necessary. Its userinfo, query
      #   and fragment are removed first ({TargetUrl.strip}): they are never
      #   sent to intake, logged, or kept on the error.
      # @return [String] "Bearer <token>"
      # @raise [ArgumentError] when base_url is nil or empty, or cannot be
      #   parsed into a scheme and host; nothing is sent anywhere. There is
      #   no no-target form any more: the old `header` with no argument
      #   returned Basic credentials, and the calls to intake itself now use
      #   {intake_header}.
      # @raise [TokenUnavailableError] when no token can be obtained; its
      #   `failure` says why. Anything unexpected raised while minting is
      #   reported the same way, as a :transport_error with that exception
      #   as `cause`.
      # @raise [ConfigurationError] when client_id or client_secret is
      #   missing; nothing is sent.
      def header(base_url)
        if base_url.nil? || base_url.to_s.empty?
          raise ArgumentError,
                "EndPointBlank::Authorization.header needs the URL you are about to call; " \
                "outbound calls to a provider are only ever authorized with a Bearer token"
        end

        # The raw URL is not repeated in the message: it is what could not
        # be parsed, and it may carry a secret.
        target = TargetUrl.strip(base_url)
        if target.nil?
          raise ArgumentError,
                "EndPointBlank::Authorization.header could not parse the URL it was given " \
                "(not shown); pass an absolute URL with a scheme and host"
        end

        # The reason must come from this call, captured under the cache's
        # mutex -- not from `last_failure` read afterwards, which another
        # thread can clear or overwrite in between.
        begin
          result = EndPointBlank::AccessTokens.token_result(target)
        rescue ConfigurationError
          raise
        rescue StandardError
          # A bug, not a failure intake reported: an unreachable intake
          # arrives as a Failure, not a raise. It still becomes the one
          # error this method documents, so a caller handling
          # TokenUnavailableError is not met by a NoMethodError instead.
          # Ruby sets the exception as `cause`; its message stays out of ours.
          raise TokenUnavailableError.new(target, unexpected_failure(target), unexpected: true)
        end

        unless result.is_a?(String)
          failure = result.is_a?(EndPointBlank::AccessTokens::Failure) ? result : nil
          raise TokenUnavailableError.new(target, failure)
        end

        "Bearer #{result}"
      end

      # The failure {header} reports for a mint that raised. The cache
      # records nothing for one, so there is no recorded Failure to hand on.
      def unexpected_failure(target)
        EndPointBlank::AccessTokens::Failure.new(
          base_url: target, outcome: :transport_error, status: nil,
          reason: "the token request failed unexpectedly", at: Time.now
        )
      end
      private :unexpected_failure

      # The Basic header for the SDK's own calls to its own intake --
      # authenticate/authorize, token minting, endpoint updates and the
      # log/request/response writers. intake already holds this service's
      # credential, so presenting it there discloses nothing.
      #
      # @api private Not for outbound calls to a provider: use {header}.
      # @return [String] "Basic <credentials>"
      # @raise [ConfigurationError] when client_id or client_secret is nil or
      #   empty. Interpolating them would silently send `Basic Og==` instead.
      def intake_header
        client_id = configuration.client_id
        client_secret = configuration.client_secret
        missing = []
        missing << "client_id" if client_id.nil? || client_id.to_s.empty?
        missing << "client_secret" if client_secret.nil? || client_secret.to_s.empty?
        unless missing.empty?
          raise ConfigurationError,
                "EndPointBlank is missing #{missing.join(" and ")}: set it with EndPointBlank.configure " \
                "or ENDPOINTBLANK_CLIENT_ID / ENDPOINTBLANK_CLIENT_SECRET. The SDK cannot authenticate " \
                "to its intake without both."
        end

        "Basic #{Base64.strict_encode64("#{client_id}:#{client_secret}")}"
      end
    end

    def self.included(base)
      base.extend(ClassMethods)
    end
  end

  # Builds Authorization headers.
  #
  # {header} is for outbound calls to a provider and only ever answers with a
  # Bearer token (raising {TokenUnavailableError} when none can be had);
  # {intake_header} is the SDK's own Basic header for calls to its own intake.
  class Authorization
    include AuthorizationMethods
  end
end
