# frozen_string_literal: true

require_relative "configuration_error"
require_relative "management/configuration"
require_relative "management/error_codes"
require_relative "management/error"
require_relative "management/page"
require_relative "management/retry_policy"
require_relative "management/idempotency_key"
require_relative "management/transport"
require_relative "management/client"

module EndPointBlank
  # The organization management API client. See {Management::Client}.
  #
  # Configure defaults once, e.g. in config/initializers/end_point_blank.rb,
  # apart from the runtime's EndPointBlank.configure:
  #
  #   EndPointBlank::Management.configure do |m|
  #     m.api_key = Rails.application.credentials.dig(:end_point_blank, :management_key)
  #   end
  #
  #   EndPointBlank::Management.client.organization
  module Management
    @configuration_mutex = Mutex.new

    class << self
      # The defaults {Client.new} reads. @return [Configuration]
      def configuration
        @configuration_mutex.synchronize { @configuration ||= Configuration.new }
      end

      # Yields {configuration} to change the defaults.
      def configure
        yield configuration
        configuration
      end

      # A new {Client} from {configuration}; +options+ override it.
      # @return [Client]
      def client(**options)
        Client.new(**options)
      end

      # Back to the built-in defaults (for tests).
      def reset_configuration!
        @configuration_mutex.synchronize { @configuration = Configuration.new }
      end
    end
  end
end
