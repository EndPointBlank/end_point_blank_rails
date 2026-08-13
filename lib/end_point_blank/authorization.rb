#!/bin/ruby

require 'base64'

module EndPointBlank
  module AuthorizationMethods
    module ClassMethods
      def configuration
        EndPointBlank::Configuration.instance
      end

      # Builds an outbound Authorization header value.
      # @param base_url [String, nil] the URL you are about to call, with any
      #   query string and fragment removed. If given, a token covering it is
      #   used (minting one if necessary) and returned as a Bearer header.
      #   Called with no argument this is the Basic form -- which is what the
      #   calls to intake itself use, since intake already holds this
      #   service's own credential.
      # @return [String] "Bearer <token>" or "Basic <credentials>"
      def header(base_url = nil)
        token = nil
        token = EndPointBlank::AccessTokens.token(base_url) if base_url

        if token
          "Bearer " + token
        else
          "Basic " + Base64.encode64(configuration.client_id + ":" + configuration.client_secret).gsub("\n", "")
        end
      end
    end

    def self.included(base)
      base.extend(ClassMethods)
    end
  end

  # Generates HTTP Basic Authorization headers using client credentials.
  # Creates a Base64-encoded string from the client_id and client_secret
  # configured in EndPointBlank::Configuration.
  # Use header class method to get a properly formatted "Basic {credentials}" header.
  class Authorization
    include AuthorizationMethods
  end
end
