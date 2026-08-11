#!/bin/ruby

require 'json'
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
          # The version is part of the key because authorization is decided per
          # endpoint version, and so is the deprecation carried back with it.
          # Without it, two callers on different versions of the same route share
          # one entry: whichever authorizes first decides both, so a client on a
          # deprecated version can get no warning, or one on a current version
          # can be told it is retiring.
          version     = VersionFinder.new.find(request)
          cache_key   = "epb_auth:#{client_auth}:#{path}:#{method}:#{app_name}:#{version}"

          cache = AuthenticationCache.instance
          # The cached value is the authorize response body, not a truthy
          # marker.
          #
          # It has to be, for two reasons. Callers parse the body — a cache hit
          # returning '' made JSON.parse raise, so a cached authorization became
          # a 500 rather than a fast success. And the body is where the
          # deprecation block lives; without it the Deprecation and Sunset
          # headers would appear only on cache misses, which reads as a flaky
          # feature rather than a missing one.
          if (cached = cache.retrieve(cache_key))
            return CachedResponse.new(201, cached)
          end

          hostname = request.host
          auth = Authorization.header(hostname)
          body = {
            path: path,
            http_method: method,
            client_auth: client_auth,
            target_hostname: hostname,
            application: app_name,
            endpoint_version: version,
            source_ip: request.remote_ip,
            uuid: request.uuid
          }
          response = Http.post(configuration.authorize_url, auth, body)

          if response&.status == 401 && auth.to_s.start_with?("Bearer ")
            # Hand back the token that was rejected rather than clearing
            # whatever is held now: under load it may already have been replaced
            # by another request that got here first, and dropping that one
            # would send the whole wave to exchange again.
            EndPointBlank::AccessTokens.instance.invalidate(auth.to_s.delete_prefix("Bearer "))
            auth = Authorization.header(hostname)
            response = Http.post(configuration.authorize_url, auth, body)
          end

          return nil if response.nil?
          EndPointBlank.logger.info "Authentication response: #{response.status} - #{response.body}"
          if response.status == 201
            cache.store(cache_key, response.body)
          elsif response.status > 299
            EndPointBlank.logger.error "Failed to authorize endpoint: #{response.status} - #{response.body}"
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
