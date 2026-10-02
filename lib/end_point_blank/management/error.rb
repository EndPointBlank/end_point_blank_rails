# frozen_string_literal: true

require "json"
require_relative "error_codes"

module EndPointBlank
  # Reopened with the same superclass in end_point_blank.rb; declared here too
  # so this file can be required on its own.
  class Error < StandardError; end

  module Management
    # Raised by {Client} for every refused or failed management API call.
    #
    # The API answers errors as
    # <tt>{"error": {"code", "message", "details"}}</tt>. +code+ is stable and
    # meant for programs; match on it (see {ErrorCodes}). +message+ is for
    # people. +details+ is present only when there is something field-level to
    # say, e.g. a +validation_failed+ error's fields.
    #
    # A code this SDK does not know still raises, carrying that code. An answer
    # that is not the API's error shape (an HTML page from a proxy) raises with
    # code +http_error+; a request that never got an answer raises with code
    # +connection_error+ and no status.
    class Error < EndPointBlank::Error
      # @return [String] the API's error code, or one of {ErrorCodes::SDK}
      attr_reader :code
      # @return [Object, nil] field-level details, as the API sent them
      attr_reader :details
      # @return [Integer, nil] the HTTP status; nil for +connection_error+
      attr_reader :status
      # @return [Numeric, nil] the Retry-After header's seconds, when present
      attr_reader :retry_after
      # @return [String, nil] the Location header, e.g. on +idempotency_replay_unavailable+
      attr_reader :location
      # @return [String, nil] the X-Request-Id header, for support requests
      attr_reader :request_id
      # @return [String, nil] the HTTP method of the failed request
      attr_reader :http_method
      # @return [String, nil] the path of the failed request (no query, no host)
      attr_reader :path

      # rubocop:disable Metrics/ParameterLists
      def initialize(message, code:, status: nil, details: nil, retry_after: nil, location: nil,
                     request_id: nil, http_method: nil, path: nil)
        @code = code
        @status = status
        @details = details
        @retry_after = retry_after
        @location = location
        @request_id = request_id
        @http_method = http_method
        @path = path
        super(message)
      end
      # rubocop:enable Metrics/ParameterLists

      # Builds the error for an answer outside 2xx. +headers+ is any Hash-like
      # whose keys are header names in any case.
      def self.from_response(status:, headers:, body:, http_method: nil, path: nil)
        code, message, details = parse_body(status, body)
        if code == ErrorCodes::IDEMPOTENCY_REPLAY_UNAVAILABLE
          message = replay_unavailable_message(header(headers, "location"))
        end

        new(message,
            code: code, status: status, details: details,
            retry_after: parse_retry_after(header(headers, "retry-after")),
            location: header(headers, "location"), request_id: header(headers, "x-request-id"),
            http_method: http_method, path: path)
      end

      # Whether this error is +code+ (a String or Symbol).
      def code?(code)
        self.code == code.to_s
      end

      def inspect
        "#<#{self.class.name} code=#{code.inspect} status=#{status.inspect} message=#{message.inspect}>"
      end

      class << self
        # The case-insensitive value of header +name+, or nil.
        def header(headers, name)
          return nil if headers.nil?

          headers.each { |key, value| return value.to_s if key.to_s.casecmp?(name) }
          nil
        end

        # Seconds to wait from a Retry-After header: delta-seconds, or an
        # HTTP-date. nil when absent or unreadable; never negative.
        def parse_retry_after(value)
          return nil if value.nil? || value.strip.empty?
          return Integer(value.strip, 10) if value.strip.match?(/\A\d+\z/)

          require "time"
          [Time.httpdate(value.strip) - Time.now, 0].max
        rescue ArgumentError
          nil
        end

        private

        def parse_body(status, body)
          error = JSON.parse(body.to_s)["error"]
          if error.is_a?(Hash) && error["code"].is_a?(String)
            message = error["message"].is_a?(String) ? error["message"] : "The request failed (#{error["code"]})."
            return [error["code"], message, error["details"]]
          end

          unexpected(status, body)
        rescue JSON::ParserError, TypeError, NoMethodError
          unexpected(status, body)
        end

        def unexpected(status, body)
          snippet = body.to_s.strip.gsub(/\s+/, " ")[0, 200]
          message = "The management API answered HTTP #{status} without its JSON error shape"
          message += snippet.empty? ? "." : ": #{snippet}"
          [ErrorCodes::HTTP_ERROR, message, nil]
        end

        def replay_unavailable_message(location)
          message = +"A request with this Idempotency-Key already succeeded, and its answer held a secret " \
                     "that is shown only once, so it can't be replayed and was not retried. Read or list " \
                     "the resource to see its current state"
          message << " (#{location})" if location
          message << ". If you need a secret you never received, rotate the credential."
          message
        end
      end
    end
  end
end
