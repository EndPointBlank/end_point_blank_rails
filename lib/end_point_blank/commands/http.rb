require 'excon'
require_relative '../version'

module EndPointBlank
  module Commands
    module Http
      MAX_ATTEMPTS = 3
      RETRY_DELAY  = 0.2

      # Per-attempt timeouts (seconds). Kept short because every call site in
      # this lib is fire-and-forget telemetry: a slow/unreachable intake must
      # never block the host application's request thread.
      CONNECT_TIMEOUT = 3
      READ_TIMEOUT    = 5

      # Shared Excon options so the timeout values live in exactly one place.
      # Merge this into any `Excon.post`/`Excon.new` call in the lib.
      TIMEOUT_OPTIONS = { connect_timeout: CONNECT_TIMEOUT, read_timeout: READ_TIMEOUT }.freeze

      # The x-epb-sdk value sent on every call to intake: ruby/<version>, the
      # version of this gem as loaded (sc-1463). intake ignores it today; it is
      # there so intake can record the oldest version seen per credential for
      # the move gate. That gate's minimum Ruby version is the release that
      # turns derive_base_url_from_client_id on by default, not the one that
      # added this header: with the option at its default, this version keeps
      # calling in.endpointblank.com after its organization moves.
      def self.sdk_header
        "ruby/#{EndPointBlank::VERSION}"
      end

      # The headers for every call to intake. Use this for any
      # `Excon.post`/`Excon.new` call in the lib, so x-epb-sdk cannot be left
      # off one of them.
      def self.headers(auth)
        { 'Authorization' => auth, 'Content-Type' => 'application/json', 'x-epb-sdk' => sdk_header }
      end

      def self.post(url, auth, body)
        attempt = 0
        begin
          attempt += 1
          Excon.post(
            url,
            headers: headers(auth),
            body: body.to_json,
            **TIMEOUT_OPTIONS
          )
        rescue Excon::Error => e
          # Excon::Error::Timeout (raised for both connect_timeout and
          # read_timeout) is a subclass of Excon::Error, so it is handled
          # here the same as any other transport error: retried, then
          # swallowed with a log line rather than raised to the caller.
          if attempt < MAX_ATTEMPTS
            sleep RETRY_DELAY
            retry
          end
          EndPointBlank.logger.error \
            "[EndPointBlank] HTTP POST to #{url} failed after #{MAX_ATTEMPTS} attempts: #{e.message}"
          nil
        end
      end
    end
  end
end
