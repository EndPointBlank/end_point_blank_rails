#!/bin/ruby

require 'base64'
require_relative 'token_unavailable_error'

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
      # @param base_url [String] the URL you are about to call, with any
      #   query string and fragment removed. A token covering it is used,
      #   minting one if necessary.
      # @return [String] "Bearer <token>"
      # @raise [ArgumentError] when base_url is nil or empty. There is no
      #   no-target form any more: the old `header` with no argument returned
      #   Basic credentials, and the calls to intake itself now use
      #   {intake_header}.
      # @raise [TokenUnavailableError] when no token can be obtained; its
      #   `failure` says why.
      def header(base_url)
        if base_url.nil? || base_url.to_s.empty?
          raise ArgumentError,
                "EndPointBlank::Authorization.header needs the URL you are about to call; " \
                "outbound calls to a provider are only ever authorized with a Bearer token"
        end

        token = EndPointBlank::AccessTokens.token(base_url)
        raise TokenUnavailableError.new(base_url, EndPointBlank::AccessTokens.last_failure(base_url)) unless token

        "Bearer #{token}"
      end

      # The Basic header for the SDK's own calls to its own intake --
      # authenticate/authorize, token minting, endpoint updates and the
      # log/request/response writers. intake already holds this service's
      # credential, so presenting it there discloses nothing.
      #
      # @api private Not for outbound calls to a provider: use {header}.
      # @return [String] "Basic <credentials>"
      def intake_header
        "Basic #{Base64.strict_encode64("#{configuration.client_id}:#{configuration.client_secret}")}"
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
