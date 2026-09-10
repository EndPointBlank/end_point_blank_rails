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
          # `Authorization.header`, as EndpointAuthorize and the JS, Java and
          # Python ports of this command all use. It previously read
          # `"Basic #{AuthorizationGenerate.generate}"` -- a second constant
          # this gem has never defined, so the only caller of this command
          # could not have reached the network even once the caller's own
          # missing constant was fixed. Fixing one without the other just moves
          # the NameError a frame deeper.
          #
          # Called with no argument this already returns a complete
          # "Basic <base64>" string; wrapping it in another "Basic " would send
          # `Basic Basic ...` and intake would refuse every request.
          auth = Authorization.header
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
          EndPointBlank.logger.info "Authentication response: #{response.status} - #{response.body}"
          if response.status > 299
            EndPointBlank.logger.error "Failed to authenticate: #{response.status} - #{response.body}"
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
