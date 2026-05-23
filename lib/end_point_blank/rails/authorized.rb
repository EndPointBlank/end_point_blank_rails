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
          raise UnauthorizedError.new(authorize_error_message(result), result&.status || 503)
        end
        result_json = JSON.parse(result.body)
        app_env_id = result_json['data'][0]['source_application_environment_id']
        ::EndPointBlank::Rack::EnvStore.set_source_application_environment_id(app_env_id)
      end

      private

      def authorize_error_message(result)
        return "Authorization service unavailable" if result.nil?

        parsed = JSON.parse(result.body) rescue nil
        detail = parsed.is_a?(Hash) ? parsed["error"] : nil
        "Authorization failed: #{detail || result.body}"
      end
    end
  end
end