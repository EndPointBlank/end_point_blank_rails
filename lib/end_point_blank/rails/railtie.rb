require 'rails/railtie' if defined?(::Rails)

module EndPointBlank
  module Rails
    class Railtie < ::Rails::Railtie
      initializer 'endpointblank.middleware.rails' do |app|
        require 'end_point_blank/rails/railtie'

        app.config.middleware.insert_after ActionDispatch::DebugExceptions,
                                          EndPointBlank::Middleware::Rack::ReportInteraction
      end
    end
  end
end