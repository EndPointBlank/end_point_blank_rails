# frozen_string_literal: true

module EndPointBlank
  # Reopened with the same superclass in end_point_blank.rb; declared here too
  # so this file can be required on its own.
  class Error < StandardError; end

  # Raised when a setting the SDK cannot work without is missing -- today, a
  # nil or empty client_id or client_secret when the SDK builds the Basic
  # header for a call to its own intake.
  #
  # Loud on purpose (sc-1469). Before sc-1469 the header was built with
  # `client_id + ":" + client_secret`, which raised on a nil; interpolation
  # does not, and would quietly send `Basic Og==` (base64 of ":") on every
  # call, which intake rejects as a bad credential -- a misconfiguration
  # dressed up as a revoked one.
  class ConfigurationError < Error; end
end
