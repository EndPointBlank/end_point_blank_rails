module EndPointBlank
  module Rack
    module Headers
      # Headers the SDK never sends to intake, lower-cased and matched in any
      # letter case (sc-1470).
      #
      # A request record used to carry every inbound header, so a caller's
      # `Authorization: Basic client_id:secret` or bearer token, a proxy
      # credential and its session cookie landed in the provider's request log
      # unless the provider had written a masking rule for them. The writers
      # drop these before masking runs, rather than mask them, so no rule and
      # no mask_hook can bring them back. `Set-Cookie` never arrives on a
      # request; it is listed so a response record can never carry it either.
      SENSITIVE_HEADERS = %w[authorization proxy-authorization cookie set-cookie].freeze

      def self.extract
        env = ::EndPointBlank::Rack::EnvStore.get
        return {} if env.nil?

        env.select { |k,v| k.start_with? 'HTTP_'}.
          transform_keys { |k| k.sub(/^HTTP_/, '').split('_').map(&:capitalize).join('-') }
      end

      # The request's headers as a request or response record may send them:
      # {extract} without any of {SENSITIVE_HEADERS}.
      def self.reportable
        without_sensitive(extract)
      end

      # A new hash of `headers` without any of {SENSITIVE_HEADERS}, whatever
      # their letter case. Never changes its argument; nil is {}.
      def self.without_sensitive(headers)
        return {} if headers.nil?

        headers.reject { |name, _value| SENSITIVE_HEADERS.include?(name.to_s.downcase) }
      end
    end
  end
end
