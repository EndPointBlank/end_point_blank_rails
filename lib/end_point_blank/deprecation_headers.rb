# frozen_string_literal: true

require "time"

module EndPointBlank
  # Formats the deprecation facts returned by an authorize call into the
  # standard response headers.
  #
  #   Deprecation  RFC 9745 — an Item Structured Header Date: "@1688169599"
  #   Sunset       RFC 8594 — an HTTP-date: "Sat, 31 Dec 2018 23:59:59 GMT"
  #
  # RFC 9745 permits a past value ("was deprecated at that date"), which is what
  # EndPointBlank emits: deprecation takes effect when it is declared.
  #
  # Pure and stateless on purpose. The SDK does not know what a lifecycle is —
  # it relays two timestamps the portal already decided about, and this turns
  # them into two strings. That keeps the vectors in
  # docs/superpowers/specs/2026-08-01-header-vectors.md assertable without
  # constructing a request.
  module DeprecationHeaders
    DEPRECATION = "Deprecation"
    SUNSET = "Sunset"

    # Fixed English abbreviations. Ruby's %a/%b are locale-independent, but
    # spelling them out removes the question entirely — a server running under a
    # different locale must still emit an HTTP-date.
    DAYS = %w[Sun Mon Tue Wed Thu Fri Sat].freeze
    MONTHS = %w[Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec].freeze

    class << self
      # @param deprecation [Hash, nil] the authorize response's "deprecation"
      #   block: {"deprecated_at" => iso8601, "sunset_at" => iso8601 | nil}
      # @return [Hash] header name => value; empty when there is nothing to say
      def build(deprecation)
        return {} unless deprecation.is_a?(Hash)

        headers = {}

        if (at = parse(deprecation["deprecated_at"] || deprecation[:deprecated_at]))
          headers[DEPRECATION] = deprecation_value(at)
        end

        if (at = parse(deprecation["sunset_at"] || deprecation[:sunset_at]))
          headers[SUNSET] = sunset_value(at)
        end

        headers
      end

      # "@1688169599" — no quotes, no sub-second precision.
      def deprecation_value(time)
        "@#{time.to_i}"
      end

      # "Sat, 31 Dec 2018 23:59:59 GMT" — day-of-month zero padded, always GMT.
      def sunset_value(time)
        t = time.utc
        format(
          "%s, %02d %s %04d %02d:%02d:%02d GMT",
          DAYS[t.wday], t.day, MONTHS[t.month - 1], t.year, t.hour, t.min, t.sec
        )
      end

      private

      # Never raise into the provider's response path. A malformed timestamp
      # from the portal is a bug worth no header; it is not worth a 500 on a
      # request that already succeeded.
      #
      # Types are matched rather than coerced. `Time.parse(12345)` does not
      # raise — it happily returns a date in 2012 — so a `to_s` here would turn
      # a nonsense value into a plausible-looking header, which is the one
      # outcome worse than no header at all.
      def parse(value)
        case value
        when Time then value.utc
        when String then parse_string(value)
        end
      end

      def parse_string(value)
        return nil if value.empty?

        Time.parse(value).utc
      rescue ArgumentError, TypeError
        nil
      end
    end
  end
end
