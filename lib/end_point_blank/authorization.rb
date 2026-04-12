#!/bin/ruby

module EndPointBlank
  module AuthorizationMethods
    module ClassMethods
      def configuration
        EndPointBlank::Configuration.instance
      end

      def header(hostname = nil)
        token = nil
        token = EndPointBlank::AccessTokens.token(hostname) if hostname

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
