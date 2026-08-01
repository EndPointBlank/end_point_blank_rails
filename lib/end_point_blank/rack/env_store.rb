module EndPointBlank
  module Rack
    class EnvStore
      KEY = 'end_point_blank.rack_env'.freeze
      SOURCE_ENV_ID_KEY = 'end_point_blank.source_application_environment_id'.freeze
      DEPRECATION_KEY = 'end_point_blank.deprecation'.freeze

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

      # The authorize response's deprecation block, stashed on the way in so the
      # response middleware can turn it into headers on the way out. Thread-local
      # like the rest of this store, and cleared with it.
      def self.set_deprecation(deprecation)
        Thread.current[DEPRECATION_KEY] = deprecation
      end

      def self.deprecation
        Thread.current[DEPRECATION_KEY]
      end

      def self.clear
        Thread.current[KEY] = nil
        Thread.current[SOURCE_ENV_ID_KEY] = nil
        Thread.current[DEPRECATION_KEY] = nil
      end
    end
  end
end