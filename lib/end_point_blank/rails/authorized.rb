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
        result_json = JSON.parse(result.body)
        if !result || result.status != 201
          raise UnauthorizedError, "Authentication failed: #{result_json['error']}"
        end
        app_env_id = result_json['data'][0]['source_application_environment_id']
        ::EndPointBlank::Rack::EnvStore.set_source_application_environment_id(app_env_id)
      end
    end
  end
end