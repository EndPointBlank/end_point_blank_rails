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
          status ||= e.respond_to?(:status) && e.status || 401
          body ||= e.message
          raise e
        rescue Exception => e
          # The exception will be rendered by ActionDispatch::DebugExceptions
          # (or ShowExceptions in prod), which sits outside this middleware,
          # so we never see the rendered status / body. Synthesize them so the
          # response row still gets recorded — intake requires a non-nil status.
          status ||= 500
          body ||= "#{e.class}: #{e.message}"
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
