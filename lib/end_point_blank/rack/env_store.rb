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
      # response middleware can turn it into headers on the way out.
      #
      # Stored in the Rack env rather than in a thread-local, deliberately.
      # Threads are reused between requests, so a thread-local is only correct
      # for as long as something reliably clears it — here, the middleware's
      # `ensure`. Anything that set the value without that middleware in the
      # stack would leave it on the thread, and the next request served by that
      # thread could inherit a previous caller's sunset date.
      #
      # The env is per-request by construction: the server builds a fresh hash
      # for every request and `set/1` replaces it wholesale at the top of the
      # middleware. So a stale value cannot be read even if `clear/0` never
      # runs, and correctness no longer depends on cleanup happening.
      #
      # Outside a Rack request there is nowhere to put it — and no response to
      # decorate — so this is a no-op rather than an error.
      def self.set_deprecation(deprecation)
        env = get
        env[DEPRECATION_KEY] = deprecation if env
      end

      def self.deprecation
        env = get
        env && env[DEPRECATION_KEY]
      end

      def self.clear
        Thread.current[KEY] = nil
        Thread.current[SOURCE_ENV_ID_KEY] = nil
      end
    end
  end
end