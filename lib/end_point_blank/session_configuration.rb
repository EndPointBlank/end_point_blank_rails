# frozen_string_literal: true

module EndPointBlank
  # Resolves per-request session state (the current Rack env, and the name
  # of the environment the app is running in) without depending on any
  # particular framework or app server.
  class SessionConfiguration
    def self.env
      ::EndPointBlank::Rack::EnvStore.get
    end

    # Resolves the name of the environment the app is running in, without
    # assuming any particular framework or app server.
    #
    # Resolution order (first non-nil wins):
    #   1. Configuration.instance.env_name (explicit config, or the
    #      ENDPOINTBLANK_ENV environment variable)
    #   2. RACK_ENV
    #   3. APP_ENV
    #   4. A Puma "puma.config" entry in the current Rack env, if present
    #      (back-compat with earlier Puma-only behavior)
    #   5. ::Rails.env, if Rails is defined
    #   6. "production" as a final default
    #
    # Never raises, even when there is no Rack env at all (e.g. Sinatra /
    # plain Rack apps outside of a request), and always returns a String.
    def self.env_name
      Configuration.instance.env_name ||
        ENV["RACK_ENV"] ||
        ENV["APP_ENV"] ||
        puma_env_name ||
        (::Rails.env.to_s if defined?(::Rails)) ||
        "production"
    end

    # Nil-safe read of the environment name from a Puma "puma.config" entry
    # in the Rack env, if one exists. Never raises, even when there is no
    # Rack env at all, or the env has no "puma.config" key.
    def self.puma_env_name
      env&.[]("puma.config")&.options&.[](:environment)
    end
    private_class_method :puma_env_name
  end
end
