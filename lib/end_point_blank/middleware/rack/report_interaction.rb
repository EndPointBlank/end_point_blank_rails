# frozen_string_literal: true

require "ipaddr"

module EndPointBlank
  module Middleware
    module Rack
      class ReportInteraction
        attr_reader :options, :url

        def initialize(app, options = {})
          @app = app
          @mapping = options
        end

        def call(env)
          ::EndPointBlank::Rack::EnvStore.set(env)
          ::EndPointBlank::Writers::RequestWriter.write

          status, headers, body = @app.call(env)

          [status, headers, body]
        rescue ::EndPointBlank::UnauthorizedError => e
          # We don't want to log unauthorized errors as they are expected to happen
          raise e
        rescue Exception => e
          Writers::ExceptionWriter.write(e)

          raise e
        ensure
          headers = ::EndPointBlank::Rack::Headers.extract
          ::EndPointBlank::Writers::ResponseWriter.write(status:, headers:, body:)
          ::EndPointBlank::Rack::EnvStore.clear
        end

        def on_success(response)
          Rails.logger.debug("Successfully reported interaction: #{response.body}")
        end

        def on_failure(response)
          Rails.logger.error("Failed to report interaction: #{response.body}")
        end
      end
    end
  end
end
