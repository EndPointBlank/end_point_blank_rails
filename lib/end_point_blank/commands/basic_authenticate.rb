#!/bin/ruby

require 'excon'

module EndPointBlank
  module Commands
    module BasicAuthenticateMethods
      module ClassMethods
        def configuration
          EndPointBlank::Configuration.instance
        end

        def authenticate(request)
          client_auth = request.headers['Authorization']
          auth = AuthorizationGenerate.generate
          puts "Authenticating request: #{request.request_method} #{request.path} with client_auth: #{client_auth}"
          response = Excon.post(configuration.authorize_url,
            headers: {'Authorization' => "Basic #{auth}", 'Content-Type' => 'application/json'},
            body: {
              path: request.route_uri_pattern.to_s.gsub(/\([^)]*\)/, ''),
              http_method: request.request_method,
              client_auth: client_auth,
              application: Configuration.instance.app_name,
              endpoint_version: VersionFinder.new.find(request),
              ip_address: request.remote_ip
            }.to_json
          )
          ::Rails.logger.info "Authentication response: #{response.status} - #{response.body}"
          if response.status > 299
            ::Rails.logger.error "Failed to update endpoint: #{response.status} - #{response.body}"
          else
            ::Rails.logger.info "Endpoint updated successfully: #{response.status}"
          end
          response
        rescue => e
          ::Rails.logger.error "Error occurred during authentication: #{e.message}\n #{e.backtrace.join("\n")}"
          nil
        end
      end

      def self.included(base)
        base.extend(ClassMethods)
      end
    end

    # Authenticates incoming requests by sending request details to a remote authorization service.
    # Sends the request path, HTTP method, client authorization header, application name,
    # API version, and client IP address to the configured authorize_url for validation.
    # Returns the HTTP response from the authorization service or nil if an error occurs.
    class BasicAuthenticate
      include BasicAuthenticateMethods
    end
  end
end
