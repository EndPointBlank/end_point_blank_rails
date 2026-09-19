# frozen_string_literal: true

require "logger"
require "rack"

require_relative "end_point_blank/access_tokens"
require_relative "end_point_blank/authorization"
require_relative "end_point_blank/version"
require_relative "end_point_blank/configuration"
require_relative "end_point_blank/base_url"
require_relative "end_point_blank/session_configuration"
require_relative "end_point_blank/log_entry"
require_relative "end_point_blank/string_truncator"
require_relative "end_point_blank/fast_json_truncator"
require_relative "end_point_blank/xml_truncator"
require_relative "end_point_blank/masking"
require_relative "end_point_blank/deprecation_headers"
require_relative "end_point_blank/writers/shared"
require_relative "end_point_blank/writers/delayed_writer"
require_relative "end_point_blank/writers/direct_writer"
require_relative "end_point_blank/writers/log_writer"
require_relative "end_point_blank/writers/exception_writer"
require_relative "end_point_blank/writers/request_writer"
require_relative "end_point_blank/writers/response_writer"
require_relative "end_point_blank/commands/generate_access_token"
require_relative "end_point_blank/commands/authentication_cache"
require_relative "end_point_blank/commands/basic_authenticate"
require_relative "end_point_blank/commands/bearer_generate"
require_relative "end_point_blank/commands/endpoint_authorize"
require_relative "end_point_blank/commands/route_pattern_finder"
require_relative "end_point_blank/commands/endpoint_update"
require_relative "end_point_blank/commands/version_finder"
require_relative "end_point_blank/middleware/rack/report_interaction"
require_relative "end_point_blank/rack/env_store"
require_relative "end_point_blank/rack/headers"
require_relative "end_point_blank/unauthorized_error"
if defined?(::Rails)
  require_relative "end_point_blank/rails/authenticated"
  require_relative "end_point_blank/rails/authorized"
  require_relative "end_point_blank/rails/versioned"
  require_relative "end_point_blank/rails/railtie"
end

module EndPointBlank
  class Error < StandardError; end

  # Applies a block of configuration changes to the shared {Configuration}
  # instance atomically: either every assignment in the block succeeds, or
  # none of them are kept.
  #
  # Each setter runs against the live singleton as the block executes, so a
  # validating setter (like {Configuration#cache_ttl=}) can raise partway
  # through a multi-field block. Before yielding, every current value is
  # snapshotted; if the block raises, every value is restored to its
  # snapshot before the error propagates, so a call that sets several
  # fields and then fails validation on one of them leaves the
  # configuration exactly as it was before the call -- not half-updated.
  #
  # This is generic over every field {Configuration} has now or gains later
  # (including a future sc-1265 cache_ttl upper bound): it snapshots and
  # restores every instance variable, so no new setter needs to be added
  # here for its validation to be atomic.
  #
  # @raise whatever the block raises, after rolling back
  def self.configure(&block)
    config = Configuration.instance
    snapshot = config.instance_variables.each_with_object({}) do |ivar, memo|
      memo[ivar] = config.instance_variable_get(ivar)
    end

    yield config
  rescue StandardError
    snapshot.each { |ivar, value| config.instance_variable_set(ivar, value) }
    raise
  end

  # Defaults to stderr, not stdout. This logger belongs to a library running
  # inside someone else's process: anything it writes to stdout lands in the
  # host application's own output. That corrupts any program whose stdout
  # carries structured data -- a CLI emitting JSON, a worker writing a protocol
  # stream -- and the host has no way to tell the two apart.
  #
  # Diagnostics belong on stderr for exactly this reason. Set
  # `EndPointBlank.logger=` to override.
  def self.logger
    Configuration.instance.logger || (@default_logger ||= ::Logger.new($stderr, level: ::Logger::INFO))
  end

  def self.logger=(logger)
    Configuration.instance.logger = logger
  end
end
