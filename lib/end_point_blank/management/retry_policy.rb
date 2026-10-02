# frozen_string_literal: true

require_relative "error"

module EndPointBlank
  module Management
    # Decides whether a failed management API request is sent again, and
    # after how long. See {Transport} for the rules.
    class RetryPolicy
      RETRYABLE_STATUSES = [500, 502, 503, 504].freeze

      # GET and DELETE are idempotent; POST always carries an Idempotency-Key.
      # PATCH is neither, so a 5xx or a lost answer to one is never re-sent.
      RETRYABLE_METHODS = %w[GET DELETE POST].freeze

      # Wait before retrying a 409 in progress that has no Retry-After header.
      IN_PROGRESS_WAIT = 1
      # First backoff for a 5xx or a request with no answer; doubles per attempt.
      BACKOFF_BASE = 0.5

      attr_reader :max_retries, :max_retry_wait

      def initialize(max_retries:, max_retry_wait:)
        @max_retries = max_retries
        @max_retry_wait = max_retry_wait
      end

      # Seconds to wait before attempt number +attempt+ + 1 (0 is the first
      # retry), or nil when +error+ must be raised now.
      def delay(method, error, attempt)
        return nil if attempt >= max_retries

        seconds = wanted_wait(method, error, attempt)
        # A wait longer than max_retry_wait is not waited out.
        seconds && seconds <= max_retry_wait ? seconds : nil
      end

      private

      def wanted_wait(method, error, attempt)
        return error.retry_after || BACKOFF_BASE if error.status == 429
        return in_progress_wait(method, error) if error.code?(ErrorCodes::IDEMPOTENCY_REQUEST_IN_PROGRESS)
        return nil unless server_side_failure?(error) && RETRYABLE_METHODS.include?(method)

        error.retry_after || backoff(attempt)
      end

      # Only a POST carries the key the first request is still running under.
      def in_progress_wait(method, error)
        method == "POST" ? error.retry_after || IN_PROGRESS_WAIT : nil
      end

      def server_side_failure?(error)
        error.code?(ErrorCodes::CONNECTION_ERROR) || RETRYABLE_STATUSES.include?(error.status)
      end

      def backoff(attempt)
        [BACKOFF_BASE * (2**attempt), max_retry_wait].min
      end
    end
  end
end
