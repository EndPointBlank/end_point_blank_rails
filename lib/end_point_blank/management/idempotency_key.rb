# frozen_string_literal: true

require "securerandom"

module EndPointBlank
  module Management
    # The Idempotency-Key a management API request carries: every POST has
    # one, so a retry of it is replayed by the API rather than run twice.
    module IdempotencyKey
      MAX_LENGTH = 255

      # The key to send for +method+: the caller's (stripped, as the API reads
      # it), or a new random UUID v4 for a POST without one; nil for any other
      # method, which must not be given one.
      #
      # @raise [ArgumentError] for a key on a non-POST, or an empty or
      #   too-long key
      def self.resolve(method, key)
        unless method == "POST"
          raise ArgumentError, "idempotency_key applies to POST requests only" unless key.nil?

          return nil
        end
        return SecureRandom.uuid if key.nil?

        key = key.to_s.strip
        return key if key.length.between?(1, MAX_LENGTH)

        raise ArgumentError, "idempotency_key must be 1 to #{MAX_LENGTH} characters"
      end
    end
  end
end
