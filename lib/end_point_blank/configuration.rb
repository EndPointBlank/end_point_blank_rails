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

    # Seconds an authorization decision stays cached when cache_ttl is never
    # assigned. See {#cache_ttl=}.
    DEFAULT_CACHE_TTL = 300

    DEFAULT_BASE_URL = "https://in.endpointblank.com"

    # sc-1463: an organization's intake answers at
    # https://<slug>.in.endpointblank.com. See {#base_url}.
    DERIVED_BASE_URL_SUFFIX = ".in.endpointblank.com"

    # app_portal's Organizations.Slug.valid?/1: a domain label of up to 20
    # [a-z0-9-] characters that starts and ends alphanumeric, then "-" and 6
    # random characters. Copied, not loosened.
    CLIENT_ID_SLUG = /\A[a-z0-9](?:[a-z0-9-]{0,18}[a-z0-9])?-[a-z0-9]{6}\z/

    attr_writer :client_id, :client_secret, :base_url, :log_base_url, :app_name, :env_name

    attr_accessor :worker_count, :log_mode,
                  :version_finder, :application_version, :token_ttl,
                  :masking_rules, :mask_hook, :logger, :trust_proxy_headers

    attr_reader :cache_ttl, :derive_base_url_from_client_id

    def initialize
      @worker_count = 4
      @token_ttl = nil
      self.cache_ttl = DEFAULT_CACHE_TTL
      @masking_rules = []
      @mask_hook = nil
      @trust_proxy_headers = true
      @derive_base_url_from_client_id = false
    end

    # Sets the authorization decision cache's TTL, in whole seconds.
    #
    # sc-970 sets one rule for this setting across every EndPointBlank SDK:
    #
    # - never assigned: the default, {DEFAULT_CACHE_TTL} (300) seconds;
    # - 0: the cache is disabled;
    # - a positive Integer: that many seconds;
    # - anything else -- an explicit nil, a negative number, or a non-Integer
    #   such as "300" or 3.5 -- raises ArgumentError here, at configure time,
    #   and leaves the previous value in place. It is never deferred to the
    #   first cache read or store, and never quietly read as "disabled" or
    #   as "use the default".
    #
    # @raise [ArgumentError] if value is not a non-negative Integer
    def cache_ttl=(value)
      unless value.is_a?(Integer) && !value.negative?
        raise ArgumentError,
              "EndPointBlank::Configuration#cache_ttl must be a non-negative Integer number of " \
              "seconds, got #{value.inspect}. To use the default of #{DEFAULT_CACHE_TTL} seconds, " \
              "omit the cache_ttl setting entirely; set it to 0 to disable the cache."
      end

      @cache_ttl = value
    end

    # Whether {#base_url} may derive the intake hostname from a slug-prefixed
    # {#client_id} when no base URL is set (sc-1463). Defaults to false,
    # because *.in.endpointblank.com has no DNS or TLS in production yet; it
    # will default to true in a later release.
    #
    # Only true or false: a String "true" from an env var must not quietly
    # leave derivation off, and nothing else has a sensible reading. Like
    # {#cache_ttl=}, anything else raises here, at configure time, and
    # leaves the previous value in place.
    #
    # @raise [ArgumentError] if value is not true or false
    def derive_base_url_from_client_id=(value)
      unless [true, false].include?(value)
        raise ArgumentError,
              "EndPointBlank::Configuration#derive_base_url_from_client_id must be true or false, " \
              "got #{value.inspect}."
      end

      @derive_base_url_from_client_id = value
    end

    # The organization slug a client_id names, or nil for one without it
    # (issued before sc-1463).
    #
    # The same rule as app_portal's Credentials.client_id_slug/1 and every
    # other EndPointBlank SDK: the part before the first "." must have the
    # exact shape of an organization slug, and something must follow the
    # dot. "Contains a ." is not enough, because app_portal has always
    # accepted a typed client_id, so a legacy "my.client" can exist and must
    # keep calling the default intake.
    #
    # @param client_id [Object] anything; only a String can carry a slug
    # @return [String, nil]
    def self.client_id_slug(client_id)
      return nil unless client_id.is_a?(String)
      # Total, like Elixir's: split and match? raise on invalid bytes or on an
      # encoding that is not ASCII-compatible (UTF-16), and neither can be a
      # credential that authenticates.
      return nil unless client_id.valid_encoding? && client_id.encoding.ascii_compatible?

      slug, random = client_id.split(".", 2)
      return nil if random.nil? || random.empty?

      CLIENT_ID_SLUG.match?(slug) ? slug : nil
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
    # ENDPOINTBLANK_BASE_URL environment variable, then -- only while
    # {#derive_base_url_from_client_id} is on -- the hostname derived from a
    # slug-prefixed {#client_id}, then a built-in default.
    def base_url
      @base_url || ENV["ENDPOINTBLANK_BASE_URL"] || derived_base_url || DEFAULT_BASE_URL
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

    private

    # sc-1463: a new client_id is "<organization slug>.<random>", and that
    # organization's intake answers at https://<slug>.in.endpointblank.com.
    # Only while derive_base_url_from_client_id is on: *.in.endpointblank.com
    # has no DNS or TLS in production yet, so it defaults off, and off means
    # today's default for every client_id. Logs are not derived: whether they
    # get a per-organization hostname is still open, so log_base_url keeps its
    # own default.
    def derived_base_url
      return nil unless @derive_base_url_from_client_id == true

      slug = self.class.client_id_slug(client_id)
      slug && "https://#{slug}#{DERIVED_BASE_URL_SUFFIX}"
    end
  end
end
