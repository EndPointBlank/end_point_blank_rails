# frozen_string_literal: true

# Loads the two Rails guard concerns into a Rails-free spec environment.
#
# `end_point_blank.rb` requires everything under `lib/end_point_blank/rails/`
# only `if defined?(::Rails)`, and ::Rails is deliberately not defined here, so
# without this the concerns are never loaded by the suite at all. That is
# precisely how `Rails::Authenticated` shipped calling a constant that has never
# existed: a file no spec requires and no application includes is invisible to a
# coverage number.
#
# `ActiveSupport::Concern` comes from `spec/stubbed_gems/`, and both the load
# path entry and the constant are removed again immediately afterwards --
# `generate_access_token_no_rails_spec.rb` asserts `defined?(ActiveSupport)` is
# nil as a sanity check, and `no_rails_spec.rb` asserts the same of ::Rails.
# `extend` and the `included do` block are both evaluated at load time, so the
# stub is only needed while these two `require`s run; the resulting singleton
# methods outlive the constant.
stubbed_active_support = !defined?(ActiveSupport)
stub_path = File.expand_path("../stubbed_gems", __dir__)

$LOAD_PATH.unshift(stub_path) if stubbed_active_support

require "end_point_blank/rails/authenticated"
require "end_point_blank/rails/authorized"

if stubbed_active_support
  $LOAD_PATH.delete(stub_path)
  Object.send(:remove_const, :ActiveSupport) if Object.const_defined?(:ActiveSupport, false)
end
