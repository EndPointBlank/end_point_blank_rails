# frozen_string_literal: true

require "uri"
require_relative "configuration"
require_relative "error"
require_relative "transport"
require_relative "resources/base"
require_relative "resources/api_packages"
require_relative "resources/clients"
require_relative "resources/applications"

module EndPointBlank
  module Management
    # A client for the EndPointBlank organization management API (app_portal's
    # +/api/v1+): your organization's API packages, clients, package
    # assignments, grants, applications, environments and runtime credentials,
    # and the managed clients you run for your customers.
    #
    # Plain Ruby: usable from a script, a job or a console as well as a Rails
    # app. It authenticates only with a management API key
    # (<tt>Authorization: Bearer epb_mk_...</tt>, created in the portal under
    # Settings > API Keys) and shares nothing with the runtime configuration:
    # it never sends a runtime client_id/client_secret and never calls intake.
    #
    #   mgmt = EndPointBlank::Management::Client.new(api_key: ENV.fetch("EPB_MGMT_KEY"))
    #   mgmt.organization                  # => {"id" => ..., "name" => ..., ...}
    #   mgmt.api_packages.each { |package| puts package["name"] }
    #
    # Arguments left nil fall back to {Management.configure} (and its
    # ENDPOINTBLANK_MANAGEMENT_* environment variables), then the defaults.
    #
    # Thread-safe: each request opens its own connection.
    class Client
      KEY_PREFIX = "epb_mk_"
      # The prefix and at least one more character, with no whitespace.
      KEY_FORMAT = /\Aepb_mk_\S+\z/.freeze

      # The options {#initialize} takes besides api_key and base_url.
      OPTIONS = %i[max_retries max_retry_wait connect_timeout read_timeout sleeper excon_options].freeze

      DEFAULT_SLEEPER = ->(seconds) { Kernel.sleep(seconds) }

      # @return [Resources::ApiPackages]
      attr_reader :api_packages
      # @return [Resources::Endpoints]
      attr_reader :endpoints
      # @return [Resources::Clients]
      attr_reader :clients
      # @return [Resources::PackageAssignments]
      attr_reader :package_assignments
      # @return [Resources::Grants]
      attr_reader :grants
      # @return [Resources::Applications]
      attr_reader :applications
      # @return [Resources::Environments]
      attr_reader :environments
      # @return [Resources::Credentials]
      attr_reader :credentials

      # @param api_key [String] a management API key, epb_mk_...
      # @param base_url [String] app_portal's URL (default https://app.endpointblank.com)
      # @param max_retries [Integer] retries after the first attempt; 0 turns them off
      # @param max_retry_wait [Numeric] the longest single wait, in seconds
      # @param connect_timeout [Numeric] seconds
      # @param read_timeout [Numeric] seconds
      # @param sleeper [#call] called with the seconds to wait before a retry
      #   (default Kernel#sleep); replace it in tests
      # @param excon_options [Hash] extra options for Excon.new (e.g. a proxy,
      #   or <tt>mock: true</tt> with Excon.stub in tests)
      # @raise [EndPointBlank::ConfigurationError] for a missing or malformed key or base URL
      def initialize(api_key: nil, base_url: nil, **options)
        unknown = options.keys - OPTIONS
        raise ArgumentError, "unknown option(s): #{unknown.join(", ")}" unless unknown.empty?

        config = Management.configuration
        @transport = Transport.new(
          api_key: self.class.validate_key(api_key || config.api_key),
          base_url: self.class.validate_base_url(base_url || config.base_url),
          **transport_options(config, options)
        )
        build_resources
      end

      # app_portal's URL this client calls.
      def base_url
        @transport.base_url
      end

      # GET /organization: the organization the key belongs to, and the key's
      # name and scope.
      # @return [Hash] <tt>{"id", "name", "domain", "slug", "key" => {"name", "scope"}}</tt>
      def organization
        body = @transport.request("GET", "/organization")
        body.is_a?(Hash) ? body["data"] : body
      end

      # A view of the API as your managed client +client_id+ (a client
      # created with <tt>clients.create_managed</tt>): its applications,
      # environments and credentials, under /clients/:client_id/. Works only
      # while the client is unclaimed; afterwards every call answers 404.
      #
      # @return [ManagedClient]
      def for_managed_client(client_id)
        ManagedClient.new(@transport, client_id, @clients)
      end

      # Never shows the key.
      def inspect
        "#<#{self.class.name} base_url=#{base_url.inspect} api_key=[REDACTED]>"
      end
      alias to_s inspect

      # The key, if it is a management API key. The error never repeats it.
      # @api private
      def self.validate_key(api_key)
        return api_key if api_key.is_a?(String) && api_key.match?(KEY_FORMAT)

        given = api_key.nil? || api_key == "" ? "No key was given" : "The key given does not have that form"
        raise EndPointBlank::ConfigurationError,
              "EndPointBlank::Management::Client needs a management API key: #{KEY_PREFIX} followed by " \
              "the rest of the key, as the portal shows it under Settings > API Keys. #{given}. " \
              "Runtime client credentials are not accepted by the management API."
      end

      # +base_url+ without a trailing slash, if it is an http(s) URL with a
      # host and no userinfo, query or fragment. The error never repeats it,
      # since a URL can carry credentials.
      # @api private
      def self.validate_base_url(base_url)
        return base_url.to_s.sub(%r{/+\z}, "") if plain_http_url?(base_url)

        raise EndPointBlank::ConfigurationError,
              "The management API base_url must be an http(s) URL with a host and no userinfo, " \
              "query or fragment, such as #{Configuration::DEFAULT_BASE_URL}."
      end

      def self.plain_http_url?(base_url)
        uri = URI.parse(base_url.to_s)
        %w[http https].include?(uri.scheme) && !uri.host.to_s.empty? &&
          [uri.userinfo, uri.query, uri.fragment].all?(&:nil?)
      rescue URI::InvalidURIError
        false
      end
      private_class_method :plain_http_url?

      private

      def transport_options(config, options)
        {
          max_retries: non_negative(:max_retries, options.fetch(:max_retries, config.max_retries)),
          max_retry_wait: non_negative(:max_retry_wait, options.fetch(:max_retry_wait, config.max_retry_wait)),
          connect_timeout: options.fetch(:connect_timeout, config.connect_timeout),
          read_timeout: options.fetch(:read_timeout, config.read_timeout),
          sleeper: options.fetch(:sleeper, DEFAULT_SLEEPER),
          excon_options: options.fetch(:excon_options, {})
        }
      end

      def non_negative(name, value)
        return value if value.is_a?(Numeric) && !value.negative?

        raise ArgumentError, "#{name} must be a non-negative number, got #{value.inspect}"
      end

      def build_resources
        @api_packages = Resources::ApiPackages.new(@transport)
        @endpoints = Resources::Endpoints.new(@transport)
        @clients = Resources::Clients.new(@transport)
        @package_assignments = Resources::PackageAssignments.new(@transport)
        @grants = Resources::Grants.new(@transport)
        @applications = Resources::Applications.new(@transport)
        @environments = Resources::Environments.new(@transport)
        @credentials = Resources::Credentials.new(@transport)
      end
    end

    # Your managed client's applications, environments and credentials, from
    # {Client#for_managed_client}. The same calls as the {Client}'s own,
    # sent under /api/v1/clients/:client_id/.
    class ManagedClient
      # @return [String] the client's id (as in /clients/:client_id)
      attr_reader :client_id
      # @return [Resources::Applications]
      attr_reader :applications
      # @return [Resources::Environments]
      attr_reader :environments
      # @return [Resources::Credentials]
      attr_reader :credentials

      def initialize(transport, client_id, clients)
        prefix = "/clients/#{Resources::Base.escape(client_id)}"
        @client_id = client_id
        @clients = clients
        @applications = Resources::Applications.new(transport, prefix)
        @environments = Resources::Environments.new(transport, prefix)
        @credentials = Resources::Credentials.new(transport, prefix)
      end

      # The client itself (GET /clients/:client_id). @return [Hash]
      def get
        @clients.get(client_id)
      end

      # POST /clients/:client_id/claim_invites: emails your customer an
      # invite to claim the client. @return [Hash]
      def claim_invite(email:, idempotency_key: nil)
        @clients.claim_invite(client_id, email: email, idempotency_key: idempotency_key)
      end

      def inspect
        "#<#{self.class.name} client_id=#{client_id.inspect}>"
      end
    end
  end
end
