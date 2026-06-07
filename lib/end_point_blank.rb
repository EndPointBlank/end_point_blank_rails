# frozen_string_literal: true

require_relative "end_point_blank/access_tokens"
require_relative "end_point_blank/authorization"
require_relative "end_point_blank/version"
require_relative "end_point_blank/configuration"
require_relative "end_point_blank/session_configuration"
require_relative "end_point_blank/log_entry"
require_relative "end_point_blank/string_truncator"
require_relative "end_point_blank/fast_json_truncator"
require_relative "end_point_blank/xml_truncator"
require_relative "end_point_blank/masking"
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

  # Your code goes here...
  def self.configure(&block)
    yield Configuration.instance
  end
end
