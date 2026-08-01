# frozen_string_literal: true

# A minimal stand-in for the parts of Rails and ActiveSupport that this gem's
# Rails-only code paths reach for, installed only for the duration of a
# `with_fake_rails` block.
#
# It has to be scoped rather than global. Several specs deliberately assert
# that `::Rails` and ActiveSupport's String/Object extensions are absent, since
# that is what proves the framework-agnostic core really is framework-agnostic
# (see no_rails_spec.rb). Leaving a stub installed would quietly retire those
# guarantees.
#
# The alternative -- adding `rails` as a development dependency -- would pull a
# whole framework in to exercise the handful of methods listed below, and would
# make it impossible to test the Rails-free paths in the same suite.
module FakeRails
  # ActiveSupport's Object#blank?/#present?, verbatim in behaviour: nil and
  # false are blank, anything answering #empty? is blank when empty.
  OBJECT_METHODS = {
    blank?: -> { respond_to?(:empty?) ? !!empty? : !self },
    present?: -> { !blank? }
  }.freeze

  STRING_METHODS = {
    camelize: -> { split("/").map { |part| part.split("_").map(&:capitalize).join }.join("::") },
    underscore: -> { gsub("::", "/").gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase },
    constantize: -> { Object.const_get(self) }
  }.freeze

  MODULE_METHODS = {
    module_parent_name: -> { name&.include?("::") ? name.split("::")[0..-2].join("::") : nil }
  }.freeze

  # @param application [Object] stands in for ::Rails.application
  # @param env [String] stands in for ::Rails.env
  def with_fake_rails(application: nil, env: "test")
    install_extensions
    rails = Module.new
    rails.define_singleton_method(:application) { application }
    rails.define_singleton_method(:env) { env }
    Object.const_set(:Rails, rails)

    yield rails
  ensure
    Object.send(:remove_const, :Rails) if Object.const_defined?(:Rails, false)
    remove_extensions
  end

  private

  def install_extensions
    OBJECT_METHODS.each { |name, body| Object.send(:define_method, name, &body) }
    STRING_METHODS.each { |name, body| String.send(:define_method, name, &body) }
    MODULE_METHODS.each { |name, body| Module.send(:define_method, name, &body) }
  end

  def remove_extensions
    OBJECT_METHODS.each_key { |name| Object.send(:remove_method, name) }
    STRING_METHODS.each_key { |name| String.send(:remove_method, name) }
    MODULE_METHODS.each_key { |name| Module.send(:remove_method, name) }
  end
end
