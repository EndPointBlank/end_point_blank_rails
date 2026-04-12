require 'debug'

module EndPointBlank
  class SessionConfiguration
    def self.env
      ::EndPointBlank::Rack::EnvStore.get
    end

    def self.env_name
      env['puma.config'].options[:environment]
    end
  end
end