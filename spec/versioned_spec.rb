# frozen_string_literal: true

require 'spec_helper'

# `activesupport` is not a declared dependency of this gem and is not loaded in
# this spec environment — see no_rails_spec.rb, which stubs at boundaries for the
# same reason. `Versioned` uses exactly one feature of ActiveSupport::Concern,
# `class_methods do`, so this provides just that rather than pulling Rails into
# the test suite to exercise thirty lines of merge logic.
#
# The constant is removed again immediately after `require`. Two other specs
# assert `defined?(ActiveSupport)` is nil as a deliberate sanity check that this
# environment is Rails-free, and leaving the stub in place breaks them. It is
# only needed while `versioned.rb` is being loaded — `extend` happens once, at
# module definition, and the resulting singleton methods outlive the constant.
stubbed_active_support = !defined?(ActiveSupport)

if stubbed_active_support
  module ActiveSupport
    module Concern
      def class_methods(&block)
        mod =
          if const_defined?(:ClassMethods, false)
            const_get(:ClassMethods)
          else
            const_set(:ClassMethods, Module.new)
          end

        mod.module_eval(&block)
      end

      def append_features(base)
        super
        base.extend(const_get(:ClassMethods)) if const_defined?(:ClassMethods, false)
      end
    end
  end
end

require 'end_point_blank/rails/versioned'

Object.send(:remove_const, :ActiveSupport) if stubbed_active_support

# `version` had no spec coverage before this — the suite passed the entire
# flat-array change without exercising it once. These pin the merge semantics
# the manifest depends on.
RSpec.describe EndPointBlank::Rails::Versioned do
  def controller_class
    Class.new do
      include EndPointBlank::Rails::Versioned

      def index; end
      def show; end
      def destroy; end
    end
  end

  it 'records versions as a flat array' do
    klass = controller_class
    klass.version %w[v1 v2], only: [:index]

    expect(klass.versions(:index)).to eq(%w[v1 v2])
  end

  it 'merges repeated declarations, deduplicated, in declaration order' do
    # Order matters: a manifest that reorders between deploys churns the payload
    # and makes every deploy look like a change.
    klass = controller_class
    klass.version %w[v1 v2], only: [:index]
    klass.version %w[v2 v3], only: [:index]

    expect(klass.versions(:index)).to eq(%w[v1 v2 v3])
  end

  it 'returns an empty array for an action with no declaration' do
    expect(controller_class.versions(:index)).to eq([])
  end

  it 'applies to the actions named by :only' do
    klass = controller_class
    klass.version %w[v1], only: %i[index show]

    expect(klass.versions(:index)).to eq(%w[v1])
    expect(klass.versions(:show)).to eq(%w[v1])
    expect(klass.versions(:destroy)).to eq([])
  end

  it 'applies to every action the controller defines when no options are given' do
    klass = controller_class
    klass.version %w[v1]

    expect(klass.versions(:index)).to eq(%w[v1])
    expect(klass.versions(:show)).to eq(%w[v1])
    expect(klass.versions(:destroy)).to eq(%w[v1])
  end

  it 'applies to every action except those named by :except' do
    klass = controller_class
    klass.version %w[v1], except: [:destroy]

    expect(klass.versions(:index)).to eq(%w[v1])
    expect(klass.versions(:destroy)).to eq([])
  end

  it 'ignores a :state option rather than grouping by it' do
    # `state` is no longer part of the API. Passing it is harmless — it is just
    # an unrecognised key in the options hash alongside :only/:except — and must
    # not resurrect per-state grouping.
    klass = controller_class
    klass.version %w[v1], only: [:index], state: 'Current'

    expect(klass.versions(:index)).to eq(%w[v1])
  end
end
