#!/bin/ruby

require 'excon'

module EndPointBlank
  module Commands
    # Collects and sends application endpoint information to a remote registry service.
    # Scans all Rails routes and extracts details including path, HTTP verb, API version,
    # and deprecation status from controller versioning concerns. Sends this data along
    # with application metadata (name, hostname, environment) to the configured endpoint_update_url
    # for centralized endpoint tracking and documentation.
    class EndpointUpdate
      def initialize
      end

      def configuration
        EndPointBlank::Configuration.instance
      end

      def auth
        Authorization.header
      end

      def write(data)
        response = Excon.post(configuration.endpoint_update_url,
          headers: {'Authorization' => auth, 'Content-Type' => 'application/json'},
          body: data.to_json
        )
        if response.status > 299
          ::Rails.logger.error "Failed to update endpoint: #{response.status} - #{response.body}"
        else
          ::Rails.logger.info "Endpoint updated successfully: #{response.status}"
        end
      end

      def self.update
        new.update
      end

      def update
        write(application_info)
      end

      def application_info
        {
          application: application_name,
          hostname: hostname,
          lib_version: EndPointBlank::VERSION,
          environment: environment,
          endpoints: ,
          app_version: ,
        }
      end

      private

      def app_version
        return configuration.application_version if configuration.respond_to?(:application_version) && configuration.application_version.present?

        nil
      end

      def application_name
        ::Rails.application.class.module_parent_name.underscore
      end

      def hostname
        # Try to get hostname from various sources
        if defined?(::Rails) && ::Rails.application.config.respond_to?(:force_ssl) && ::Rails.application.config.force_ssl
          protocol = 'https'
        else
          protocol = 'http'
        end

        host = if ::Rails.application.config.respond_to?(:host)
                 ::Rails.application.config.host
               elsif defined?(ActionMailer) && ActionMailer::Base.default_url_options[:host]
                 ActionMailer::Base.default_url_options[:host]
               else
                 'localhost'
               end

        port = ::Rails.application.config.respond_to?(:port) ? ::Rails.application.config.port : nil
        port_suffix = port && port != 80 && port != 443 ? ":#{port}" : ""

        "#{host}#{port_suffix}"
      end

      def environment
        ::Rails.env
      end

      def endpoints
        ::Rails.application.routes.routes.map do |route|
          if route.defaults[:controller].nil? || route.defaults[:action].nil?
            nil
          else
            controller_class = "#{route.defaults[:controller].camelize}Controller".constantize
            versions = controller_class.respond_to?(:versions) ? controller_class.versions(route.defaults[:action].to_sym) : {}
            {
              path: route.path.spec.to_s.gsub(/\([^)]*\)/, ''),
              http_method: route.verb,
              endpoint_versions: versions,
            }
          end
        end.compact.uniq.filter { |e| e[:path].present? && !(e[:path].start_with?('/rails/') || e[:path] == '/assets' || e[:endpoint_versions].empty?)}
      end

      def extract_version_from_path(path)
        match = path.match(/\/v(\d+)\//)
        match ? "v#{match[1]}" : nil
      end
    end
  end
end