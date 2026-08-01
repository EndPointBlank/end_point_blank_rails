module EndPointBlank
  module Rack
    # Per-request state, keyed off the Rack env.
    #
    # Only the env itself is held in a thread-local; everything derived from a
    # request lives *inside* that env. That distinction is the whole point.
    #
    # Threads are reused between requests, so a thread-local is correct only for
    # as long as something reliably clears it — here, the middleware's `ensure`.
    # Anything that set a value without that middleware in the stack would
    # strand it on the thread, and the next request served by that thread could
    # read the previous caller's data: their app-environment id on our audit
    # row, their sunset date on our response.
    #
    # The env is per-request by construction. The server builds a fresh hash per
    # request and `set/1` replaces it wholesale at the top of the middleware, so
    # a stranded value is unreachable even if `clear/0` never runs. Correctness
    # stops depending on cleanup happening.
    #
    # Outside a Rack request there is nowhere to put anything and no response to
    # decorate, so the writers are no-ops and the readers return nil.
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

      # The calling service's application environment, resolved by `authorize!`
      # and stamped onto every audit row for this request.
      def self.set_source_application_environment_id(id)
        put(SOURCE_ENV_ID_KEY, id)
      end

      def self.source_application_environment_id
        fetch(SOURCE_ENV_ID_KEY)
      end

      # The authorize response's deprecation block, stashed on the way in so the
      # response middleware can turn it into `Deprecation` and `Sunset` headers
      # on the way out.
      def self.set_deprecation(deprecation)
        put(DEPRECATION_KEY, deprecation)
      end

      def self.deprecation
        fetch(DEPRECATION_KEY)
      end

      def self.clear
        Thread.current[KEY] = nil
      end

      def self.put(key, value)
        env = get
        env[key] = value if env
      end
      private_class_method :put

      def self.fetch(key)
        env = get
        env && env[key]
      end
      private_class_method :fetch
    end
  end
end
