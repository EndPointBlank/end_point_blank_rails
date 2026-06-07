# frozen_string_literal: true

require "singleton"

module EndPointBlank
  module Writers
    class RequestWriter
      include Singleton
      include DelayedWriter
      include Shared

      attr_reader :url

      def initialize
        @url = EndPointBlank::Configuration.instance.requests_url
        start_threads
      end

      def self.write(data = {})
        instance.write()
      end

      def payload
        env = ::EndPointBlank::Rack::EnvStore.get
        request = ActionDispatch::Request.new(env)
        version = Commands::VersionFinder.new.find(request)
        headers = ::EndPointBlank::Rack::Headers.extract

        payload = {
          app_name: EndPointBlank::Configuration.instance.app_name,
          env: SessionConfiguration.env_name,
          uuid: request.uuid,
          host: request.host,
          status: request_status(request),
          headers: headers,
          path: request.path,
          http_method: request.method,
          endpoint_version: version,
          request: request_body(request),
          sent_at: Time.now.utc.iso8601(3)
        }
      end

      def write()
        enqueue(apply_masking(payload, :request))
      end

      private

      def request_status(request)
        request.respond_to?(:status) ? request.status : nil
      end

      def request_body(request)
        body = request.body&.read
        request.body.rewind if request.body&.respond_to?(:rewind)
        body
      end
    end
  end
end
