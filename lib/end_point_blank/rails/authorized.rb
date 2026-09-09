require "active_support/concern"

module EndPointBlank
  module Rails
    module Authorized
      extend ActiveSupport::Concern

      included do
        before_action :authorize!
      end

      def authorize!
        result = EndPointBlank::Commands::EndpointAuthorize.authorize(request)
        if result.nil? || result.status != 201
          # Shared with `Authenticated#authenticate!`. This path has always
          # carried intake's status and that one dropped it; two copies of one
          # decision is how that happens, so there is now one copy. Nothing
          # this path produces for any input has changed -- the message and the
          # status are the same for a refusal, for a 5xx, and for an intake
          # that did not answer.
          raise UnauthorizedError.refusal_from(result, "Authorization")
        end
        result_json = JSON.parse(result.body)
        app_env_id = result_json['data'][0]['source_application_environment_id']
        ::EndPointBlank::Rack::EnvStore.set_source_application_environment_id(app_env_id)
        # Present only when the called version is deprecated; the middleware
        # turns it into Deprecation / Sunset headers on the way out.
        ::EndPointBlank::Rack::EnvStore.set_deprecation(result_json['deprecation'])
      end
    end
  end
end
