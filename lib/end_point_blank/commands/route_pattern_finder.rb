# frozen_string_literal: true

module EndPointBlank
  module Commands
    class RoutePatternFinder
      def self.find(request)
        return nil unless defined?(::Rails)

        matched = nil
        ::Rails.application.routes.router.recognize(request) do |route, _params|
          matched = route.path.spec.to_s
          break
        end
        matched
      rescue StandardError => e
        EndPointBlank.logger.debug("Error finding route pattern: #{e.message}")
        nil
      end
    end
  end
end
