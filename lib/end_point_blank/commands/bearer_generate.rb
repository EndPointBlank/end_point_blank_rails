#!/bin/ruby

module EndPointBlank
  module Commands
    BEARER_GENERATE_DEPRECATION =
      "EndPointBlank::Commands::BearerGenerate is deprecated and will be removed: its header " \
      "carries this service's own client_id/client_secret and is only valid for this service's " \
      "own EndPointBlank intake. Never send it to a provider; use " \
      "EndPointBlank::Authorization.header(base_url) for outbound calls (sc-1469).".freeze
    BEARER_GENERATE_DEPRECATION_MUTEX = Mutex.new
    private_constant :BEARER_GENERATE_DEPRECATION_MUTEX

    module BearerGenerateMethods
      module ClassMethods
        def configuration
          EndPointBlank::Configuration.instance
        end

        def generate()
          warn_deprecated
          Base64.encode64(configuration.client_id + ":" + configuration.client_secret).gsub("\n", "")
        end

        def auth_header
          "Basic " + generate
        end

        private

        # Once per process, not once per call: this sits on a request path,
        # and a warning per request would bury the log it is meant to reach.
        # The first caller wins the flag under a mutex so two threads racing
        # the first call still print one line.
        #
        # Kernel#warn with category: :deprecated is printed only while
        # Warning[:deprecated] is on (`ruby -W:deprecated`, or
        # `Warning[:deprecated] = true`), which is how Ruby gates its own
        # deprecations; the gem has no ActiveSupport outside Rails to lean on.
        def warn_deprecated
          return if @deprecation_warned

          BEARER_GENERATE_DEPRECATION_MUTEX.synchronize do
            return if @deprecation_warned

            @deprecation_warned = true
          end

          warn(BEARER_GENERATE_DEPRECATION, category: :deprecated)
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
    #
    # @deprecated The header carries this service's own client secret and is only valid
    #   for this service's own EndPointBlank intake (see Authorization.intake_header).
    #   Never send it to a provider; use Authorization.header(base_url) (sc-1469).
    class BearerGenerate
      include BearerGenerateMethods
    end
  end
end
