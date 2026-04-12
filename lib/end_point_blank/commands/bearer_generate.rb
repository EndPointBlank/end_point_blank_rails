#!/bin/ruby

module EndPointBlank
  module Commands
    module BearerGenerateMethods
      module ClassMethods
        def configuration
          EndPointBlank::Configuration.instance
        end

        def generate()
          Base64.encode64(configuration.client_id + ":" + configuration.client_secret).gsub("\n", "")
        end

        def auth_header
          "Basic " + generate
        end
      end

      def self.included(base)
        base.extend(ClassMethods)
      end
    end

    # Generates HTTP Basic Authorization headers using client credentials.
    # Creates a Base64-encoded string from the client_id and client_secret
    # configured in EndPointBlank::Configuration.
    # Use auth_header class method to get a properly formatted "Basic {credentials}" header.
    class BearerGenerate
      include BearerGenerateMethods
    end
  end
end
