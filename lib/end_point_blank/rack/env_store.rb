module EndPointBlank
  module Rack
    class EnvStore
      KEY = 'end_point_blank.rack_env'.freeze
      SOURCE_ENV_ID_KEY = 'end_point_blank.source_application_environment_id'.freeze

      def self.set(env)
        Thread.current[KEY] = env
      end

      def self.get
        Thread.current[KEY]
      end

      def self.request
        env = get
        env && ::Rack::Request.new(env)
      end

      def self.set_source_application_environment_id(id)
        Thread.current[SOURCE_ENV_ID_KEY] = id
      end

      def self.source_application_environment_id
        Thread.current[SOURCE_ENV_ID_KEY]
      end

      def self.clear
        Thread.current[KEY] = nil
        Thread.current[SOURCE_ENV_ID_KEY] = nil
      end
    end
  end
end