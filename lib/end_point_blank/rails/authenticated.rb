require "active_support/concern"

module EndPointBlank
  module Rails
    module Authenticated
     extend ActiveSupport::Concern

      included do
        before_action :authenticate!
      end

      def authenticate!
        result = EndPointBlank::Commands::EndpointAuthenticate.authenticate(request)
        result_json = JSON.parse(result.body)
        if !result || result.status != 201
          raise UnauthorizedError, "Authentication failed: #{result_json['error']}"
        end
      end
    end
  end
end