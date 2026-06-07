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

      def apply_masking(payload, record_type)
        EndPointBlank::Masking.apply(payload, record_type, configuration.masking_rules, configuration.mask_hook)
      end
    end
  end
end
