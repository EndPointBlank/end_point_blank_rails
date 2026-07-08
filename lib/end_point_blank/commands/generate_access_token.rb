#!/bin/ruby

require 'excon'
require_relative 'http'

module EndPointBlank
  module Commands
    module GenerateAccessTokenMethods
      module ClassMethods
        def configuration
          EndPointBlank::Configuration.instance
        end

        def token(hostname)
          body = {hostname: hostname}
          if configuration.token_ttl
            body[:token_ttl] = configuration.token_ttl
          end
          auth = Authorization.header
          response = Excon.post(configuration.access_token_url,
            headers: {'Authorization' => auth, 'Content-Type' => 'application/json'},
            body: body.to_json,
            **EndPointBlank::Commands::Http::TIMEOUT_OPTIONS
          )
          EndPointBlank.logger.info "Authentication response: #{response.status} - #{response.body}"
          response.body.is_a?(String) ? JSON.parse(response.body).symbolize_keys : response.body.symbolize_keys
        rescue => e
          EndPointBlank.logger.error "Error occurred during authentication: #{e.message}\n #{e.backtrace.join("\n")}"
          nil
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
