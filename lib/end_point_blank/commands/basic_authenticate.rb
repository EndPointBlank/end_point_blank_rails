#!/bin/ruby

require_relative 'http'

module EndPointBlank
  module Commands
    module BasicAuthenticateMethods
      module ClassMethods
        def configuration
          EndPointBlank::Configuration.instance
        end

        def authenticate(request)
          client_auth = request.headers['Authorization']
          auth = "Basic #{AuthorizationGenerate.generate}"
          body = {
            path: request.route_uri_pattern.to_s.gsub(/\([^)]*\)/, ''),
            http_method: request.request_method,
            client_auth: client_auth,
            application: Configuration.instance.app_name,
            endpoint_version: VersionFinder.new.find(request),
            ip_address: request.remote_ip
          }
          response = Http.post(configuration.authorize_url, auth, body)
          return nil if response.nil?
          ::Rails.logger.info "Authentication response: #{response.status} - #{response.body}"
          if response.status > 299
            ::Rails.logger.error "Failed to authenticate: #{response.status} - #{response.body}"
          end
          response
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
