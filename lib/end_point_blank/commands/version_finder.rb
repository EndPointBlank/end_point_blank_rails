module EndPointBlank
  module Commands
    # Finds the API version from an incoming request by checking multiple sources:
    # - Custom version finder configured in Configuration.instance.version_finder
    # - Accept header (e.g., application/vnd.api.v1+json)
    # - X-Api-Version header (e.g., v1)
    # - Content-Type header (e.g., application/vnd.api.v1+json)
    # - Query parameter 'version' (e.g., ?version=v1)
    # - URL path segment (e.g., /v1/resource)
    # - Controller versioning configuration (via Versioned concern)
    # Returns the version number as a string (e.g., "1") or nil if no version is found.
    class VersionFinder
      def headers
        @headers ||= ::EndPointBlank::Rack::Headers.extract
      end
      def find(request)
        return Configuration.instance.version_finder.call(request) if Configuration.instance.version_finder

        return version if respond_to?(:version)

        # Logic to determine version from request
        # This could involve checking headers, query parameters, etc.
        headers["Accept"]&.match(%r{application/vnd\.\w+\.v(\d+)}) do |m|
          return m[1]
        end

        headers["X-Api-Version"]&.match(/v(\d+)/) do |m|
          return m[1]
        end

        headers["Content-Type"]&.match(%r{application/vnd\.\w+\.v(\d+)}) do |m|
          return m[1]
        end

        request.params["version"]&.match(/v(\d+)/) do |m|
          return m[1]
        end

        request.path.match(%r{/v(\d+)/}) do |m|
          return m[1]
        end

        # Try to find version from controller versioning configuration
        version_from_controller(request)
      end

      private

      def version_from_controller(request)
        return nil unless request.respond_to?(:path_parameters)

        controller_name = request.path_parameters[:controller]
        action_name = request.path_parameters[:action]

        return nil if controller_name.nil? || action_name.nil?

        controller_class = "#{controller_name.camelize}Controller".constantize
        return nil unless controller_class.respond_to?(:versions)

        versions = controller_class.versions(action_name.to_sym)
        return nil if versions.empty?

        versions.values.flatten.first&.match(/v?(\d+)/)&.[](1)
      rescue NameError
        nil
      end
    end
  end
end
