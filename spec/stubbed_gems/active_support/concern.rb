# frozen_string_literal: true

# A stand-in for the one file `lib/end_point_blank/rails/authenticated.rb` and
# `authorized.rb` require, so those two concerns can be loaded and driven in a
# spec environment that has no Rails and no ActiveSupport in it.
#
# It lives outside `spec/support/` deliberately: `spec_helper` requires every
# file under `spec/support/**` at boot, and this one must be reachable by
# `require "active_support/concern"` and then *unloaded again*. Two other specs
# assert `defined?(ActiveSupport)` is nil as a sanity check that the
# framework-agnostic core really is framework-agnostic, and leaving a stub
# installed would quietly retire that guarantee. `spec/support/rails_concerns.rb`
# puts this directory on the load path, loads the concerns, and takes both the
# path and the constant away again.
#
# The alternative -- adding `activesupport` as a development dependency -- would
# pull a framework in to exercise the three methods below, and is the same trade
# `versioned_spec.rb` already declined for the same reason.
module ActiveSupport
  # The subset of `ActiveSupport::Concern` this gem's concerns actually use:
  # an `included do ... end` block that runs against the including class, and
  # `class_methods do ... end`. Behaviour matches the real thing for those.
  module Concern
    def self.extended(base)
      base.instance_variable_set(:@_included_block, nil)
    end

    # `included` with no argument stores a block to run later; with an argument
    # it is Ruby's ordinary inclusion callback.
    def included(base = nil, &block)
      if base.nil?
        @_included_block = block
      else
        super
      end
    end

    def append_features(base)
      super
      base.extend(const_get(:ClassMethods)) if const_defined?(:ClassMethods, false)
      base.class_eval(&@_included_block) if @_included_block
    end

    def class_methods(&block)
      mod =
        if const_defined?(:ClassMethods, false)
          const_get(:ClassMethods)
        else
          const_set(:ClassMethods, Module.new)
        end

      mod.module_eval(&block)
    end
  end
end
