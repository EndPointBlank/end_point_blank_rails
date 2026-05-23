# frozen_string_literal: true

require "singleton"

module EndPointBlank
  module Writers
    class ResponseWriter
      include Singleton
      include DelayedWriter
      include Shared

      attr_reader :url

      def initialize
        @url = EndPointBlank::Configuration.instance.responses_url
        start_threads
      end

      def self.write(status:, headers: {}, body: nil, data: {})
        instance.write(status:, headers:, body:, data:)
      end

      def payload(status:, headers:, body:, data: {})
        request = ::EndPointBlank::Rack::EnvStore.request
        env = ::EndPointBlank::Rack::EnvStore.get
        headers = ::EndPointBlank::Rack::Headers.extract
        version = request ? Commands::VersionFinder.new.find(request) : nil
        route = request ? Commands::RoutePatternFinder.find(request) : nil

        {
            app_name: app_name,
            env: env_name,
            uuid: env['action_dispatch.request_id'],
            status: status,
            headers: headers,
            body: truncate(normalize_body(body)),
            sent_at: Time.now.utc.iso8601(3),
            route: route,
            data: data,
            source_application_environment_id: source_application_environment_id
        }
      end

      def write(status:, headers: {}, body: nil, data: {})
        enqueue(payload(status:, headers:, body:, data:))
      end

      private
      def truncate(body)
        return body if body.nil? || body.length <= 1024

        body[0...1024] + "..."
      end

      def normalize_body(body)
        return nil if body.nil?

        if body.respond_to?(:body) && !body.is_a?(Array)
          body.body
        elsif body.respond_to?(:each)
          result = +""
          body.each { |chunk| result << chunk }
          result
        else
          body.to_s
        end
      end
    end
  end
end
