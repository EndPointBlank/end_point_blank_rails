# frozen_string_literal: true

require "spec_helper"
require "end_point_blank/commands/route_pattern_finder"
require "end_point_blank/commands/version_finder"

# RoutePatternFinder and VersionFinder are Rails-only lookups (::Rails.application
# routing, and ActiveSupport's #camelize/#constantize on a Rails-shaped
# controller/action pair) invoked from ResponseWriter#payload on *every*
# response. Before the ::Rails guard, RoutePatternFinder unconditionally called
# ::Rails.application, which raises NameError on every request in a plain
# Ruby / Sinatra host app (silently rescued, but with a stray `puts` and a
# real exception raised-then-caught on the request's hot path). These specs
# prove both resolve to nil, without raising, without touching $stdout, when
# ::Rails is not defined -- including the Rails-shaped-request case for
# VersionFinder where a naive respond_to?(:path_parameters) check alone
# would not have prevented reaching #camelize/#constantize.
RSpec.describe EndPointBlank::Commands::RoutePatternFinder do
  it "returns nil without raising when ::Rails is not defined" do
    expect(defined?(::Rails)).to be_falsey
    request = double("request")

    result = nil
    expect { result = described_class.find(request) }.not_to raise_error
    expect(result).to be_nil
  end

  it "does not print to $stdout when ::Rails is not defined" do
    request = double("request")

    expect { described_class.find(request) }.not_to output.to_stdout
  end
end

RSpec.describe EndPointBlank::Commands::VersionFinder do
  describe "#find against a Rails-shaped request (responds to :path_parameters) with ::Rails undefined" do
    let(:request) do
      double("request", path_parameters: { controller: "widgets", action: "show" }, params: {}, path: "/widgets")
    end

    before do
      allow(EndPointBlank::Rack::Headers).to receive(:extract).and_return({})
    end

    it "returns nil instead of raising NoMethodError on ActiveSupport's #camelize" do
      expect(defined?(::Rails)).to be_falsey

      result = nil
      expect { result = described_class.new.find(request) }.not_to raise_error
      expect(result).to be_nil
    end
  end
end
