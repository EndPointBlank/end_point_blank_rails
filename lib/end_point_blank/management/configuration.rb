# frozen_string_literal: true

module EndPointBlank
  module Management
    # Defaults for {Client.new}, set with {Management.configure}, e.g. in a
    # Rails initializer.
    #
    # Separate from {EndPointBlank::Configuration} on purpose: the runtime
    # client_id/client_secret are never sent to the management API, and the
    # management key is never sent to intake. Nothing here reads the runtime
    # configuration, and nothing in the runtime configuration reads this.
    class Configuration
      DEFAULT_BASE_URL = "https://app.endpointblank.com"
      DEFAULT_MAX_RETRIES = 2
      DEFAULT_MAX_RETRY_WAIT = 60
      DEFAULT_CONNECT_TIMEOUT = 5
      DEFAULT_READ_TIMEOUT = 30

      attr_writer :api_key, :base_url

      # Retries after the first attempt (see {Transport}). 0 turns them off.
      attr_accessor :max_retries
      # The longest wait, in seconds, a retry will sleep (a longer
      # Retry-After raises the error instead).
      attr_accessor :max_retry_wait
      attr_accessor :connect_timeout, :read_timeout

      def initialize
        @max_retries = DEFAULT_MAX_RETRIES
        @max_retry_wait = DEFAULT_MAX_RETRY_WAIT
        @connect_timeout = DEFAULT_CONNECT_TIMEOUT
        @read_timeout = DEFAULT_READ_TIMEOUT
      end

      # The management API key (epb_mk_...), falling back to the
      # ENDPOINTBLANK_MANAGEMENT_KEY environment variable.
      def api_key
        @api_key || ENV.fetch("ENDPOINTBLANK_MANAGEMENT_KEY", nil)
      end

      # app_portal's URL, falling back to the
      # ENDPOINTBLANK_MANAGEMENT_BASE_URL environment variable, then
      # {DEFAULT_BASE_URL}. Not the runtime's intake base_url.
      def base_url
        @base_url || ENV.fetch("ENDPOINTBLANK_MANAGEMENT_BASE_URL", nil) || DEFAULT_BASE_URL
      end

      # Never shows the key.
      def inspect
        "#<#{self.class.name} base_url=#{base_url.inspect} api_key=#{api_key ? "[REDACTED]" : "nil"} " \
          "max_retries=#{max_retries.inspect}>"
      end
      alias to_s inspect
    end
  end
end
