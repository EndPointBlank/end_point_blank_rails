#!/bin/ruby

require_relative 'http'
require_relative 'authentication_cache'

module EndPointBlank
  module Commands
    # Synthetic response returned on a cache hit to avoid a network call.
    CachedResponse = Struct.new(:status, :body)

    module EndpointAuthorizeMethods
      module ClassMethods
        def configuration
          EndPointBlank::Configuration.instance
        end

        def authorize(request)
          client_auth = request.headers['Authorization'].to_s
          method      = request.request_method
          path        = request.route_uri_pattern.to_s.gsub(/\([^)]*\)/, '')
          app_name    = Configuration.instance.app_name
          cache_key   = "epb_auth:#{client_auth}:#{path}:#{method}:#{app_name}"

          cache = AuthenticationCache.instance
          return CachedResponse.new(201, '') if cache.exists?(cache_key)

          hostname = request.host
          auth = Authorization.header(hostname)
          body = {
            path: path,
            http_method: method,
            client_auth: client_auth,
            target_hostname: hostname,
            application: app_name,
            endpoint_version: VersionFinder.new.find(request),
            source_ip: request.remote_ip,
            uuid: request.uuid
          }
          response = Http.post(configuration.authorize_url, auth, body)

          if response&.status == 401 && auth.to_s.start_with?("Bearer ")
            EndPointBlank::AccessTokens.instance.remove(hostname)
            auth = Authorization.header(hostname)
            response = Http.post(configuration.authorize_url, auth, body)
          end

          return nil if response.nil?
          ::Rails.logger.info "Authentication response: #{response.status} - #{response.body}"
          if response.status == 201
            cache.store(cache_key, true)
          elsif response.status > 299
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
