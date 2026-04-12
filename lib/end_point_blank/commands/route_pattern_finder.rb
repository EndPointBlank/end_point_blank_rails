# frozen_string_literal: true

require "debug"

module EndPointBlank
  module Commands
    class RoutePatternFinder
      def self.find(request)
        matched = nil
        ::Rails.application.routes.router.recognize(request) do |route, _params|
          matched = route.path.spec.to_s
          break
        end
        matched
      rescue StandardError => e
        puts "Error finding route pattern: #{e.message}"
        nil
      end
    end
  end
end
