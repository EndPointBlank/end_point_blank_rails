#!/bin/ruby

require 'json'
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
            # `source_ip`, which is the key intake reads. This sent
            # `ip_address` from the beginning -- and js, py and java copied it
            # faithfully, so all four were wrong together until sc-320 fixed
            # the three ports. intake ignores keys it does not cast, so nothing
            # ever failed: `source_ip_address` was simply NULL on every
            # authenticate row from a Rails application, and every per-source-IP
            # question about authenticate traffic read as though there were
            # none. EndpointAuthorize on the next path over has always sent it
            # under the right name.
            source_ip: request.remote_ip
          }
          response = Http.post(configuration.authorize_url, auth, body)
          return nil if response.nil?
          EndPointBlank.logger.info "Authentication response: #{response.status} - #{response.body}"
          if response.status == 201
            source_env_id = source_application_environment_id(response.body)
            ::EndPointBlank::Rack::EnvStore.set_source_application_environment_id(source_env_id)
          end
          if response.status > 299
            EndPointBlank.logger.error "Failed to authenticate: #{response.status} - #{response.body}"
          end
          response
        end

        private

        def source_application_environment_id(body)
          parsed = JSON.parse(body)
          id = parsed.dig('data', 0, 'source_application_environment_id')
          return id if id.is_a?(String) && !id.empty?

          EndPointBlank.logger.error(
            "Authenticated, but the authorize response has no " \
            "data[0].source_application_environment_id, so this request's responses, " \
            "logs and errors will not name their caller: body=#{body}"
          )
          nil
        rescue JSON::ParserError => error
          EndPointBlank.logger.error(
            "Authenticated, but the authorize response has no " \
            "data[0].source_application_environment_id, so this request's responses, " \
            "logs and errors will not name their caller: #{error.message}"
          )
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
