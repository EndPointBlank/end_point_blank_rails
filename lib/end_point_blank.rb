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

  # Serializes {EndPointBlank.configure} calls. Without this, two calls
  # racing each other could each copy the same starting state, and
  # whichever finished applying last would silently discard the other's
  # committed changes -- including a call that raised doing exactly that to
  # a concurrent call that had already succeeded. See {EndPointBlank.configure}.
  @configure_mutex = Mutex.new

  # Applies a block of configuration changes to the shared {Configuration}
  # instance atomically: either every assignment in the block succeeds, or
  # none of them are kept.
  #
  # The block receives a detached copy of the configuration, not the live
  # singleton, and the copy's values are only written onto the live
  # singleton after the block returns normally. That makes the atomicity
  # structural rather than a rollback: if the block raises -- any
  # exception, not only StandardError -- the live singleton was never
  # touched in the first place, so there is nothing to undo. This also
  # covers a field the block sets for the very first time (e.g. client_id
  # on a fresh boot, before {Configuration#initialize} has ever assigned
  # it): the assignment lands on the copy and is discarded with it.
  #
  # {Configuration#masking_rules} and its rule Hashes are duplicated into
  # the copy, so `c.masking_rules << rule` or mutating a rule Hash the
  # caller already installed can never reach the live list before the
  # block succeeds. Objects the caller owns and hands in by reference --
  # {Configuration#logger}, {Configuration#mask_hook},
  # {Configuration#version_finder} -- are copied by reference, like any
  # other field; EndPointBlank.configure cannot and does not roll back
  # mutation the caller performs on those objects themselves.
  #
  # This is generic over every field {Configuration} has now or gains
  # later (including a future sc-1265 cache_ttl upper bound): it copies
  # every instance variable, so no new setter needs to be added here for
  # its validation to be atomic.
  #
  # Calls are serialized with a module-level Mutex held across both the
  # block and the commit (see {@configure_mutex}), so two calls from
  # different threads can never interleave their reads and writes: the
  # second one always starts from whatever the first one left behind,
  # whether the first succeeded or raised. The lock only orders
  # configure-against-configure; a reader elsewhere that is not going
  # through configure can still observe the commit loop's writes one field
  # at a time while it runs.
  #
  # @raise whatever the block raises; the live configuration is left
  #   exactly as it was before the call
  def self.configure
    @configure_mutex.synchronize do
      config = Configuration.instance
      candidate = configure_candidate_for(config)

      yield candidate

      apply_configure_candidate(config, candidate)
    end
  end

  # Builds the detached copy {EndPointBlank.configure} yields to its block:
  # every current instance variable of +config+, copied onto a bare
  # {Configuration} instance that was never handed through Singleton's
  # +instance+ (so it stays a private scratch object, not a second
  # singleton). masking_rules is duplicated one level deep -- the array and
  # each rule Hash in it -- since it is the one documented mutable,
  # in-place-editable field.
  def self.configure_candidate_for(config)
    candidate = Configuration.send(:allocate)
    config.instance_variables.each do |ivar|
      value = config.instance_variable_get(ivar)
      value = value.map(&:dup) if ivar == :@masking_rules && value.is_a?(Array)
      candidate.instance_variable_set(ivar, value)
    end
    candidate
  end
  private_class_method :configure_candidate_for

  # Copies every instance variable the block set on +candidate+ onto the
  # live +config+. Only reached after the block has returned normally.
  def self.apply_configure_candidate(config, candidate)
    candidate.instance_variables.each do |ivar|
      config.instance_variable_set(ivar, candidate.instance_variable_get(ivar))
    end
  end
  private_class_method :apply_configure_candidate

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
