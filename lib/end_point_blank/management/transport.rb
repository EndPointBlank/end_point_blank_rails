# frozen_string_literal: true

require "excon"
require "json"
require "uri"
require_relative "../version"
require_relative "error"
require_relative "retry_policy"
require_relative "idempotency_key"

module EndPointBlank
  module Management
    # The HTTP layer under {Client}: one request to the management API, with
    # its headers, its Idempotency-Key and its retries. Built on Excon, the
    # HTTP library the rest of this gem already uses.
    #
    # Retries (at most +max_retries+ after the first attempt, each wait passed
    # to +sleeper+):
    #
    # - 429 +rate_limited+, any method: after Retry-After seconds. Nothing was
    #   done, so even a PATCH is safe to send again. A Retry-After longer than
    #   +max_retry_wait+ is not waited out; the error is raised instead.
    # - 409 +idempotency_request_in_progress+ (POST only): shortly, with the
    #   same key, so the first request's answer is replayed once it finishes.
    # - 5xx (+internal_server_error+, +audit_unavailable+,
    #   +intake_unavailable+, or a proxy's 502/503/504) and requests that never
    #   got an answer: for GET and DELETE, which are idempotent, and for POST,
    #   which always carries an Idempotency-Key. Never for PATCH.
    #
    # Every POST carries an Idempotency-Key (a random UUID v4 unless the
    # caller passed one), and every retry of it sends the same key.
    #
    # 409 +idempotency_replay_unavailable+ is never retried: the first POST
    # succeeded and its answer held a secret shown only once.
    class Transport
      API_PREFIX = "/api/v1"

      attr_reader :base_url

      # rubocop:disable Metrics/ParameterLists
      def initialize(api_key:, base_url:, max_retries:, max_retry_wait:, connect_timeout:, read_timeout:,
                     sleeper:, excon_options: {})
        @api_key = api_key
        @base_url = base_url
        @base_path = URI.parse(base_url).path.sub(%r{/+\z}, "")
        @retry_policy = RetryPolicy.new(max_retries: max_retries, max_retry_wait: max_retry_wait)
        @connect_timeout = connect_timeout
        @read_timeout = read_timeout
        @sleeper = sleeper
        @excon_options = excon_options
      end
      # rubocop:enable Metrics/ParameterLists

      # Sends one API request and answers its decoded JSON body (nil for an
      # empty body). +path+ is under /api/v1, e.g. "/organization".
      #
      # @raise [Error] for any answer outside 2xx, once retries are spent
      def request(method, path, query: nil, body: nil, idempotency_key: nil)
        method = method.to_s.upcase
        idempotency_key = IdempotencyKey.resolve(method, idempotency_key)
        attempt = 0

        loop do
          result = attempt_request(method, path, query, body, idempotency_key)
          return result unless result.is_a?(Error)

          wait_before_retry(method, path, result, attempt)
          attempt += 1
        end
      end

      def self.user_agent
        "end_point_blank-ruby/#{EndPointBlank::VERSION} (management)"
      end

      def inspect
        "#<#{self.class.name} base_url=#{base_url.inspect}>"
      end

      private

      # The decoded body on success, or the Error to raise or retry on.
      def attempt_request(method, path, query, body, idempotency_key)
        response = perform(method, path, query, body, idempotency_key)
        return Error.from_response(**error_fields(response, method, path)) unless success?(response)

        decode(response, method, path)
      rescue Excon::Error::StubNotFound
        raise
      rescue Excon::Error => e
        connection_error(e, method, path)
      end

      def perform(method, path, query, body, idempotency_key)
        connection = Excon.new(base_url, connect_timeout: @connect_timeout, read_timeout: @read_timeout,
                                         write_timeout: @read_timeout, persistent: false, **@excon_options)
        params = { method: method, path: "#{@base_path}#{API_PREFIX}#{path}",
                   headers: headers(body, idempotency_key) }
        params[:query] = query if query && !query.empty?
        params[:body] = JSON.generate(body) unless body.nil?
        connection.request(params)
      end

      def headers(body, idempotency_key)
        headers = {
          "Authorization" => "Bearer #{@api_key}",
          "Accept" => "application/json",
          "User-Agent" => self.class.user_agent
        }
        headers["Content-Type"] = "application/json" unless body.nil?
        headers["Idempotency-Key"] = idempotency_key if idempotency_key
        headers
      end

      def success?(response)
        (200..299).cover?(response.status)
      end

      def decode(response, method, path)
        text = response.body.to_s
        return nil if text.strip.empty?

        JSON.parse(text)
      rescue JSON::ParserError
        Error.new("The management API answered HTTP #{response.status} with a body that is not JSON.",
                  code: ErrorCodes::INVALID_RESPONSE, status: response.status, http_method: method, path: path)
      end

      def error_fields(response, method, path)
        { status: response.status, headers: response.headers, body: response.body,
          http_method: method, path: path }
      end

      def connection_error(error, method, path)
        detail = redact("#{error.class.name}: #{error.message}")
        Error.new("Could not reach the management API at #{base_url} (#{detail}).",
                  code: ErrorCodes::CONNECTION_ERROR, http_method: method, path: path)
      end

      # Sleeps before the next attempt, or raises +error+ when it is not to
      # be retried.
      def wait_before_retry(method, path, error, attempt)
        delay = @retry_policy.delay(method, error, attempt)
        raise error if delay.nil?

        log_retry(method, path, error, delay)
        @sleeper.call(delay)
      end

      # Method, path, status and code only: never headers, query or bodies,
      # which carry the key, ids and credential secrets.
      def log_retry(method, path, error, delay)
        EndPointBlank.logger.debug(
          "[EndPointBlank] management API #{method} #{path} answered " \
          "#{error.status || "no response"} (#{error.code}); retrying in #{delay}s"
        )
      end

      def redact(text)
        return text if @api_key.nil? || @api_key.empty?

        text.gsub(@api_key, "[REDACTED]")
      end
    end
  end
end
