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

  # Serializes {EndPointBlank.configure} calls end to end -- both the block
  # and the commit -- so two calls can never overlap. Without this, two
  # calls that both succeed could overlap: the second one can start while
  # the first is still running, so both build their candidate from the same
  # starting snapshot. Whichever one finishes last still decides what to
  # write by diffing its own candidate against that same snapshot, not
  # against whatever {Configuration} holds live by the time it actually
  # commits (see {apply_configure_changes}) -- so its own change still looks
  # like a change relative to its now-stale snapshot, and it writes that
  # value over whatever the other call already committed, with no error.
  # See {EndPointBlank.configure}.
  @configure_mutex = Mutex.new

  # Applies a block of configuration changes to the shared {Configuration}
  # instance atomically: either every assignment the block makes through
  # its block argument succeeds, or none of them are kept.
  #
  # The block receives a detached copy of the configuration, not the live
  # singleton. Only the fields whose value on that copy differs from an
  # independent deep copy taken before the block ran are written onto the
  # live singleton afterward, and only once the block returns normally.
  # That makes the atomicity structural rather than a rollback: if the
  # block raises -- any exception, not only StandardError -- nothing is
  # written at all. This also covers a field the block sets for the very
  # first time (e.g. client_id on a fresh boot, before
  # {Configuration#initialize} has ever assigned it): the assignment lands
  # on the copy and is discarded with it.
  #
  # Committing only the fields the block actually changed, rather than
  # every field, matters because the live singleton can change out from
  # under a configure call that never touches a given field -- a direct
  # `Configuration.instance.some_field = ...` outside configure, or
  # `EndPointBlank.logger=`, is not covered by {@configure_mutex}. Writing
  # every field back unconditionally would silently revert that kind of
  # concurrent change as soon as this call's block returned, even though
  # this call never touched the field itself.
  #
  # String, Array and Hash values -- including {Configuration#masking_rules}
  # and the Hashes in it -- are deep-copied, so an in-place edit
  # (`c.masking_rules.first[:regex] << "|.*"`, `c.app_name << "-staging"`,
  # `c.masking_rules << rule`) changes only the block's copy, never the
  # live value, unless and until that field is committed. Objects the
  # caller owns and hands in by reference -- {Configuration#logger},
  # {Configuration#mask_hook}, {Configuration#version_finder} -- are not
  # String/Array/Hash, so they are copied by reference like any other
  # field; EndPointBlank.configure cannot and does not roll back mutation
  # the caller performs on those objects themselves.
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
  # Because Ruby's Mutex is not reentrant, calling EndPointBlank.configure
  # again from inside a configure block, on the same thread, raises {Error}
  # rather than running -- configure blocks are not meant to nest. A block
  # that starts a different thread, has that thread call configure, and
  # then joins it will hang instead of raising, since that thread is
  # genuinely waiting on a lock this thread holds.
  #
  # @raise whatever the block raises, or {Error} if called while a
  #   configure call is already in progress on the same thread; the live
  #   configuration is left exactly as it was before the call
  def self.configure
    raise Error, "EndPointBlank.configure cannot be called from inside a configure block" if @configure_mutex.owned?

    @configure_mutex.synchronize do
      config = Configuration.instance
      original = configure_snapshot_for(config)
      candidate = configure_candidate_for(config)

      yield candidate

      apply_configure_changes(config, original, candidate)
    end
  end

  # Deep-copies every current instance variable of +config+ into a Hash
  # keyed by ivar name (see {configure_deep_dup}), so the result shares no
  # mutable object with +config+. {EndPointBlank.configure} calls this
  # twice per call -- once directly, for the comparison snapshot, and once
  # more via {configure_candidate_for}, for the copy the block mutates --
  # so an in-block edit to one can never be mistaken for "unchanged" by
  # comparing it back to the other.
  def self.configure_snapshot_for(config)
    config.instance_variables.each_with_object({}) do |ivar, memo|
      memo[ivar] = configure_deep_dup(config.instance_variable_get(ivar))
    end
  end
  private_class_method :configure_snapshot_for

  # Recursively duplicates plain data (String, Array, Hash). Every other
  # value -- Integer, Symbol, true/false/nil, and an object the caller owns
  # and handed in by reference such as {Configuration#logger},
  # {Configuration#mask_hook} or {Configuration#version_finder} -- is
  # returned as-is, since none of those can be edited in place through
  # {Configuration}'s documented API the way a String or a rule Hash can.
  def self.configure_deep_dup(value)
    case value
    when String then value.dup
    when Array then value.map { |element| configure_deep_dup(element) }
    when Hash
      value.each_with_object({}) { |(k, v), memo| memo[configure_deep_dup(k)] = configure_deep_dup(v) }
    else
      value
    end
  end
  private_class_method :configure_deep_dup

  # Builds the detached copy {EndPointBlank.configure} yields to its block:
  # a bare {Configuration} instance -- built with
  # `Configuration.send(:allocate)` since {Configuration} is a Singleton
  # and its `.new`/`.allocate` are private -- carrying its own independent
  # deep copy of +config+'s current ivars, so it stays a private scratch
  # object, not a second singleton, and mutating it can never reach
  # +config+.
  def self.configure_candidate_for(config)
    candidate = Configuration.send(:allocate)
    configure_snapshot_for(config).each { |ivar, value| candidate.instance_variable_set(ivar, value) }
    candidate
  end
  private_class_method :configure_candidate_for

  # Writes onto the live +config+ only the ivars whose value on +candidate+
  # differs from +original+, the independent deep copy taken before the
  # block ran. A field the block never touched is left exactly as +config+
  # has it now, even if something else changed it while the block was
  # running. Only reached after the block has returned normally.
  def self.apply_configure_changes(config, original, candidate)
    candidate.instance_variables.each do |ivar|
      value = candidate.instance_variable_get(ivar)
      config.instance_variable_set(ivar, value) unless value == original[ivar]
    end
  end
  private_class_method :apply_configure_changes

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
