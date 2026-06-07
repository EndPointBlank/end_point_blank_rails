# frozen_string_literal: true

require "singleton"

module EndPointBlank
  module Writers
    class LogWriter
      include Singleton
      include DelayedWriter
      include Shared

      attr_reader :url

      def initialize
        @url = EndPointBlank::Configuration.instance.logs_url
        start_threads
      end

      def self.info(message, data = {})
        instance.write(message, :info, data)
      end

      def self.warn(message, data = {})
        instance.write(message, :warn, data)
      end

      def self.error(message, data = {})
        instance.write(message, :error, data)
      end

      def self.fatal(message, data = {})
        instance.write(message, :fatal, data)
      end

      def self.write(message, level, data = {})
        instance.write(message, level, data)
      end

      def payload(message: message, level: level, data: data)
        env = ::EndPointBlank::Rack::EnvStore.get
        request = ActionDispatch::Request.new(env)
        uuid = request.uuid

        {
          message: message,
          log_level: level,
          sent_at: Time.now.utc.iso8601(3),
          app_name: app_name,
          uuid: uuid,
          data: data,
          source_application_environment_id: source_application_environment_id
        }
      end


      def write(message, level, data = {})
        json = payload(message: message, level: level, data: data)
        rack_req = ::EndPointBlank::Rack::EnvStore.request
        if rack_req
          json = json.merge(
            stamped_path: rack_req.path,
            stamped_http_method: rack_req.request_method
          )
        end
        puts "Writing log: #{json}"
        enqueue(json)
      end
    end
  end
end
