# frozen_string_literal: true

require "singleton"

module EndPointBlank
  module Writers
    class ExceptionWriter
      include Singleton
      include DelayedWriter
      include Shared

      attr_reader :url

      def initialize
        @url = EndPointBlank::Configuration.instance.errors_url
        start_threads
      end

      def self.write(exception)
        instance.write(exception)
      end

      def payload(exception)
        env = ::EndPointBlank::Rack::EnvStore.get
        request = ActionDispatch::Request.new(env)
        version = Commands::VersionFinder.new.find(request)
        {
          app_name: app_name,
          uuid: request.uuid,
          message: exception.message,
          stacktrace: exception.backtrace,
          sent_at: Time.now.utc.iso8601(3),
          source_application_environment_id: source_application_environment_id
        }
      end

      def write(exception)
        json = payload(exception)
        enqueue(json)
      end
    end
  end
end
