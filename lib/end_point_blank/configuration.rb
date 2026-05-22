require 'singleton'

module EndPointBlank
  class Configuration
    include Singleton

    attr_accessor :client_id, :client_secret, :base_url, :log_base_url,
          :environment, :app_name, :worker_count, :log_mode,
          :version_finder, :application_version, :token_ttl, :cache_ttl

    def initialize
      @base_url = 'https://in.endpointblank.com'
      @log_base_url = 'https://log.endpointblank.com'
      @worker_count = 4
      @token_ttl = nil
      @cache_ttl = 300
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
    # Otherwise, if the application is a Rails application, then
    # {::Rails.application.name} is returned.
    #
    # Otherwise, if the application is a Rack application, then
    # {debugger} is called.
    def app_name
      if @app_name
        @app_name
      elsif defined?(::Rails)
        ::Rails.application.name.underscore
      else
        nil
      end
    end
  end
end
