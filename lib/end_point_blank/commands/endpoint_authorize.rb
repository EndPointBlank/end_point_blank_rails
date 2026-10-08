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
          # A thread that serves more than one request, or a direct caller
          # that reuses one env, must not carry the last caller's identity
          # into this one: a refused or failed authorization leaves both ids
          # unset rather than naming whoever was authorized before.
          record_source(nil, nil)

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
          # It has to be, for three reasons. Callers parse the body — a cache hit
          # returning '' made JSON.parse raise, so a cached authorization became
          # a 500 rather than a fast success. And the body is where the
          # deprecation block lives; without it the Deprecation and Sunset
          # headers would appear only on cache misses, which reads as a flaky
          # feature rather than a missing one. And the calling organization's
          # id (sc-1571) is in it too, for the same reason. A body cached
          # before intake sent that id simply has none, and answers nil.
          if (cached = cache.retrieve(cache_key))
            record_source_ids(cached)
            return CachedResponse.new(201, cached)
          end

          # Host header only, never the forwarded chain -- see
          # BaseUrl.hostname_from_rack_env. request.host would read
          # X-Forwarded-Host unconditionally.
          hostname = EndPointBlank::BaseUrl.hostname_from_rack_env(request.env)
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

          # Basic, not Bearer. This call is to intake, which already holds
          # this service's credential -- minting a token to present it back
          # was a hop that bought nothing. With no Bearer there is no stale
          # token, so the 401 retry that used to live here is gone: a 401 now
          # means the credential is wrong, which is worth surfacing rather
          # than retrying.
          response = Http.post(configuration.authorize_url, Authorization.intake_header, body)

          return nil if response.nil?
          EndPointBlank.logger.info "Authentication response: #{response.status} - #{response.body}"
          if response.status == 201
            record_source_ids(response.body)
            cache.store(cache_key, response.body)
          elsif response.status > 299
            EndPointBlank.logger.error "Failed to authorize endpoint: #{response.status} - #{response.body}"
          end
          response
        end

        private

        def record_source(source_env_id, source_organization_id)
          ::EndPointBlank::Rack::EnvStore.set_source_application_environment_id(source_env_id)
          ::EndPointBlank::Rack::EnvStore.set_source_organization_id(source_organization_id)
        end

        def record_source_ids(body)
          record_source_application_environment_id(body)
          ::EndPointBlank::Rack::EnvStore.set_source_organization_id(source_organization_id(body))
        end

        # sc-1571: the calling organization's EndPointBlank id. An intake older
        # than the field does not send it, and an organization with no id
        # there gets null; both are nil here, silently, since neither is a
        # broken contract. A body that is not a JSON object has already been
        # logged by record_source_application_environment_id.
        def source_organization_id(body)
          parsed = JSON.parse(body)
          return nil unless parsed.is_a?(Hash)

          data = parsed['data']
          first = data.is_a?(Array) ? data.first : nil
          id = first.is_a?(Hash) ? first['source_organization_id'] : nil
          id.is_a?(String) && !id.empty? ? id : nil
        rescue JSON::ParserError
          nil
        end

        # Intake renders the grant under data[0]. The Rails controller also
        # records this value, but the command is also used directly (today,
        # by end_point_blank_deploy's conformance driver), so the command must
        # carry the grant into the request store before any writer runs.
        def record_source_application_environment_id(body)
          parsed = JSON.parse(body)
          # A 201 whose body is valid JSON but not a Hash -- `[]`, `null`,
          # `"x"` -- used to reach `dig` below and raise (TypeError for an
          # Array, NoMethodError for nil or a String), turning a request
          # intake had actually GRANTED into a crash for this direct-caller
          # path. The other SDKs all guard the type before digging into the
          # body (py: isinstance on both levels, js: optional chaining,
          # elixir: pattern match with a fallback clause); this matches them.
          unless parsed.is_a?(Hash)
            EndPointBlank.logger.error(
              "Authorized, but the response body did not parse to a JSON object, so this " \
              "request's responses, logs and errors will not name their caller: body=#{body}"
            )
            return ::EndPointBlank::Rack::EnvStore.set_source_application_environment_id(nil)
          end

          id = parsed.dig('data', 0, 'source_application_environment_id')
          # An empty string is the same absence as a missing id -- do not
          # record it, or the log line above claiming the caller "will not be
          # named" is contradicted by the very next line.
          id = nil if id == ''
          if id.nil?
            EndPointBlank.logger.error(
              "Authorized, but the response has no data[0].source_application_environment_id, " \
              "so this request's responses, logs and errors will not name their caller: body=#{body}"
            )
          end
          ::EndPointBlank::Rack::EnvStore.set_source_application_environment_id(id)
        rescue JSON::ParserError
          EndPointBlank.logger.error(
            "Authorized, but the response body is not valid JSON, so this request's responses, " \
            "logs and errors will not name their caller: body=#{body}"
          )
          ::EndPointBlank::Rack::EnvStore.set_source_application_environment_id(nil)
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
