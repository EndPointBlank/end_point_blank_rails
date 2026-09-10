require "securerandom"

module EndPointBlank
  module Writers
    module Shared
      attr_accessor :url

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
      def request_uuid(env)
        (env && env["action_dispatch.request_id"]) || SecureRandom.uuid
      end

      def apply_masking(payload, record_type)
        EndPointBlank::Masking.apply(payload, record_type, configuration.masking_rules, configuration.mask_hook)
      end
    end
  end
end
