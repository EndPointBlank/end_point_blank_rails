require 'rails/railtie' if defined?(::Rails)

module EndPointBlank
  module Rails
    class Railtie < ::Rails::Railtie
      initializer 'endpointblank.middleware.rails' do |app|
        require 'end_point_blank/rails/railtie'

        app.config.middleware.insert_after ActionDispatch::DebugExceptions,
                                          EndPointBlank::Middleware::Rack::ReportInteraction
      end

      initializer 'endpointblank.logger.rails' do
        EndPointBlank::Configuration.instance.logger ||= ::Rails.logger
      end
    end
  end
end