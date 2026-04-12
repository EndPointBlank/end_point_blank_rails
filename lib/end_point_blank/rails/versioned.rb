module EndPointBlank
  module Rails
    module Versioned
      extend ActiveSupport::Concern

      class_methods do
        # Define versioning for specific actions
        # @param versions [Array<String>] List of version strings (e.g., ["v1", "v2"])
        # @param options [Hash] Options hash with :only or :except keys
        # @option options [Array<Symbol>] :only Actions to include in versioning
        # @option options [Array<Symbol>] :except Actions to exclude from versioning
        #
        # Example:
        #   version ["v1", "v2"], only: [:index], state: "Current"
        #   version ["v3"], except: [:destroy], state: "Deprecated"
        def version(values, options = {})
          versions = Array(values)
          @versioning_config ||= {}

          actions = determine_actions(options)

          actions.each do |action|
            @versioning_config[action] ||= {}
            state = options[:state] || "__default__"
            @versioning_config[action][state] ||= []
            @versioning_config[action][state] = (@versioning_config[action][state] + versions).uniq
          end
        end

        # Returns the versioning configuration hash
        # @return [Hash] Hash mapping action names to their version arrays
        #
        # Example return value:
        #   {
        #     index: ["v1", "v2"],
        #     show: ["v1"]
        #   }
        def versions(action)
          @versioning_config&.fetch(action, {}) || {}
        end

        private

        # Determine which actions should be affected based on options
        # @param options [Hash] Options hash with :only or :except keys
        # @return [Array<Symbol>] Array of action symbols
        def determine_actions(options)
          if options[:only]
            Array(options[:only]).map(&:to_sym)
          elsif options[:except]
            # If :except is specified, we need to determine all possible actions
            # and exclude the specified ones. Get all public methods of the controller.
            all_actions = self.public_instance_methods(false).map(&:to_sym)
            excluded_actions = Array(options[:except]).map(&:to_sym)
            all_actions - excluded_actions
          else
            # If no options specified, apply to all common REST actions
            self.public_instance_methods(false).map(&:to_sym)
          end
        end
      end
    end
  end
end