module EndPointBlank
  module Rack
    module Headers
      def self.extract
        env = ::EndPointBlank::Rack::EnvStore.get
        env.select { |k,v| k.start_with? 'HTTP_'}.
          transform_keys { |k| k.sub(/^HTTP_/, '').split('_').map(&:capitalize).join('-') }
      end
    end
  end
end