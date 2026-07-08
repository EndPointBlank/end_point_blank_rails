# frozen_string_literal: true

require "singleton"

module EndPointBlank
  # Singleton configuration object for the EndPointBlank client.
  #
  # Values may be set explicitly via {EndPointBlank.configure}. Several
  # settings also fall back to ENDPOINTBLANK_* environment variables when
  # not explicitly configured, in order to support Rails-free deployments.
  class Configuration
    include Singleton

    attr_writer :client_id, :client_secret, :base_url, :log_base_url, :app_name, :env_name

    attr_accessor :worker_count, :log_mode,
                  :version_finder, :application_version, :token_ttl, :cache_ttl,
                  :masking_rules, :mask_hook, :logger

    def initialize
      @worker_count = 4
      @token_ttl = nil
      @cache_ttl = 300
      @masking_rules = []
      @mask_hook = nil
    end

    # Returns the configured client id, falling back to the
    # ENDPOINTBLANK_CLIENT_ID environment variable when not explicitly set.
    def client_id
      @client_id || ENV["ENDPOINTBLANK_CLIENT_ID"]
    end

    # Returns the configured client secret, falling back to the
    # ENDPOINTBLANK_CLIENT_SECRET environment variable when not explicitly set.
    def client_secret
      @client_secret || ENV["ENDPOINTBLANK_CLIENT_SECRET"]
    end

    # Returns the configured base URL, falling back to the
    # ENDPOINTBLANK_BASE_URL environment variable, then a built-in default.
    def base_url
      @base_url || ENV["ENDPOINTBLANK_BASE_URL"] || "https://in.endpointblank.com"
    end

    # Returns the configured log base URL, falling back to the
    # ENDPOINTBLANK_LOG_BASE_URL environment variable, then a built-in default.
    def log_base_url
      @log_base_url || ENV["ENDPOINTBLANK_LOG_BASE_URL"] || "https://log.endpointblank.com"
    end

    def endpoint_update_url
      "#{base_url}/api/application_updates"
    end

    def access_token_url
      "#{base_url}/api/access_token"
    end

    def authorize_url
      "#{base_url}/api/authorize"
    end

    def errors_url
      "#{log_base_url}/api/application_errors"
    end

    def requests_url
      "#{log_base_url}/api/application_requests"
    end

    def responses_url
      "#{log_base_url}/api/application_responses"
    end

    def logs_url
      "#{log_base_url}/api/application_logs"
    end

    # Returns the name of the application.
    #
    # If {#app_name=} is called, then that value is returned.
    #
    # Otherwise, falls back to the ENDPOINTBLANK_APP_NAME environment
    # variable.
    #
    # Otherwise, if the application is a Rails application, then
    # {::Rails.application.name} is returned.
    #
    # Otherwise, nil is returned.
    def app_name
      if @app_name
        @app_name
      elsif ENV["ENDPOINTBLANK_APP_NAME"]
        ENV["ENDPOINTBLANK_APP_NAME"]
      elsif defined?(::Rails)
        ::Rails.application.name.underscore
      end
    end

    # Returns the configured environment name, falling back to the
    # ENDPOINTBLANK_ENV environment variable when not explicitly set.
    def env_name
      @env_name || ENV["ENDPOINTBLANK_ENV"]
    end
  end
end
