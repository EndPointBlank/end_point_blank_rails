require "securerandom"

module EndPointBlank
  module Writers
    module Shared
      attr_accessor :url

      # Where a minted request_uuid is cached on the Rack env, when the env
      # carries no request id of its own. Distinct from
      # "action_dispatch.request_id" so a later Rails middleware that sets
      # the real key is never shadowed by ours -- we only ever read that key
      # first and fall back to this one.
      GENERATED_UUID_KEY = "end_point_blank.generated_request_uuid".freeze

      def configuration
        Configuration.instance
      end

      def app_name
        configuration.app_name
      end

      def env_name
        SessionConfiguration.env_name
      end

      def env
        ::EndPointBlank::Rack::EnvStore.get
      end

      def source_application_environment_id
        ::EndPointBlank::Rack::EnvStore.source_application_environment_id
      end

      # Rails' ActionDispatch::Request#uuid simply reads this same Rack env
      # key, so reading it directly is behavior-preserving when running under
      # Rails, without requiring actionpack's ActionDispatch::Request to be
      # loaded.
      #
      # Outside Rails (plain Rack / Sinatra) nothing sets that key. Falling
      # through to nil there used to be described as "graceful", but it is
      # not: intake requires `uuid` on every error/log/request/response row
      # and refuses the ones that lack it, so a nil uuid is a silently
      # dropped row, not a tolerated one. Minting a fresh uuid instead means
      # the row still lands -- correlating with nothing is strictly better
      # than not existing.
      #
      # The mint is cached back onto `env`, not just returned. RequestWriter
      # and ResponseWriter both call this with the *same* env object for one
      # HTTP request -- EnvStore hands back whatever `set/1` was given at the
      # top of the middleware, unchanged, for the life of the request. Without
      # caching, each writer's call under plain Rack would mint its own fresh
      # uuid, and the request row and the response row for a single
      # interaction would carry two different, unrelated ids -- silently
      # defeating the one thing these columns exist for. When `env` is nil
      # (an exception reported with no request in flight at all) there is no
      # shared object to cache onto and nothing to correlate across, so a
      # standalone mint every time is correct.
      def request_uuid(env)
        return SecureRandom.uuid unless env

        env["action_dispatch.request_id"] || (env[GENERATED_UUID_KEY] ||= SecureRandom.uuid)
      end

      def apply_masking(payload, record_type)
        EndPointBlank::Masking.apply(payload, record_type, configuration.masking_rules, configuration.mask_hook)
      end
    end
  end
end
