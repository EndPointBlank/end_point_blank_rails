require 'excon'

module EndPointBlank
  module Commands
    module Http
      MAX_ATTEMPTS = 3
      RETRY_DELAY  = 0.2

      def self.post(url, auth, body)
        attempt = 0
        begin
          attempt += 1
          Excon.post(
            url,
            headers: { 'Authorization' => auth, 'Content-Type' => 'application/json' },
            body: body.to_json
          )
        rescue Excon::Error => e
          if attempt < MAX_ATTEMPTS
            sleep RETRY_DELAY
            retry
          end
          ::Rails.logger.error "[EndPointBlank] HTTP POST to #{url} failed after #{MAX_ATTEMPTS} attempts: #{e.message}"
          nil
        end
      end
    end
  end
end
