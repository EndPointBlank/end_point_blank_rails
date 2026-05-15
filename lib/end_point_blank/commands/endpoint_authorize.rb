#!/bin/ruby

require_relative 'http'

module EndPointBlank
  module Commands
    module EndpointAuthorizeMethods
      module ClassMethods
        def configuration
          EndPointBlank::Configuration.instance
        end

        def authorize(request)
          client_auth = request.headers['Authorization']
          auth = Authorization.header
          body = {
            path: request.route_uri_pattern.to_s.gsub(/\([^)]*\)/, ''),
            http_method: request.request_method,
            client_auth: client_auth,
            target_hostname: request.host,
            application: Configuration.instance.app_name,
            endpoint_version: VersionFinder.new.find(request),
            source_ip: request.remote_ip,
            uuid: request.uuid
          }
          response = Http.post(configuration.authorize_url, auth, body)
          return nil if response.nil?
          ::Rails.logger.info "Authentication response: #{response.status} - #{response.body}"
          if response.status > 299
            ::Rails.logger.error "Failed to authorize endpoint: #{response.status} - #{response.body}"
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
    class EndpointAuthorize
      include EndpointAuthorizeMethods
    end
  end
end
