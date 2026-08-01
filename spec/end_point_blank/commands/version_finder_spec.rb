# frozen_string_literal: true

require "spec_helper"

# The endpoint version decides which authorization answer a caller gets and
# which deprecation warning they are told about, so where it is read from --
# and in what order -- is load-bearing.
#
# rubocop:disable Metrics/BlockLength
RSpec.describe EndPointBlank::Commands::VersionFinder do
  let(:configuration) { EndPointBlank::Configuration.instance }

  around do |example|
    original = configuration.version_finder

    example.run

    configuration.version_finder = original
    EndPointBlank::Rack::EnvStore.clear
  end

  before { EndPointBlank::Rack::EnvStore.clear }

  def request_double(path: "/widgets", params: {})
    double("request", path: path, params: params)
  end

  describe "where the version comes from" do
    it "reads a vendor version out of the Accept header" do
      EndPointBlank::Rack::EnvStore.set("HTTP_ACCEPT" => "application/vnd.widgets.v3+json")

      expect(described_class.new.find(request_double)).to eq("3")
    end

    it "reads the X-Api-Version header" do
      EndPointBlank::Rack::EnvStore.set("HTTP_X_API_VERSION" => "v2")

      expect(described_class.new.find(request_double)).to eq("2")
    end

    it "reads a version query parameter" do
      expect(described_class.new.find(request_double(params: { "version" => "v4" }))).to eq("4")
    end

    it "reads a version segment out of the path" do
      expect(described_class.new.find(request_double(path: "/v5/widgets"))).to eq("5")
    end

    it "returns nil when the request says nothing about a version" do
      expect(described_class.new.find(request_double)).to be_nil
    end

    it "ignores a path segment that only looks like a version" do
      expect(described_class.new.find(request_double(path: "/vintage/widgets"))).to be_nil
    end
  end

  describe "precedence" do
    it "prefers the Accept header over the X-Api-Version header" do
      EndPointBlank::Rack::EnvStore.set(
        "HTTP_ACCEPT" => "application/vnd.widgets.v1+json",
        "HTTP_X_API_VERSION" => "v2"
      )

      expect(described_class.new.find(request_double)).to eq("1")
    end

    it "prefers a header over the query parameter" do
      EndPointBlank::Rack::EnvStore.set("HTTP_X_API_VERSION" => "v2")

      expect(described_class.new.find(request_double(params: { "version" => "v4" }))).to eq("2")
    end

    it "prefers the query parameter over the path" do
      request = request_double(path: "/v5/widgets", params: { "version" => "v4" })

      expect(described_class.new.find(request)).to eq("4")
    end
  end

  describe "a host application's own version_finder" do
    it "is used in place of every built-in source" do
      EndPointBlank::Rack::EnvStore.set("HTTP_ACCEPT" => "application/vnd.widgets.v1+json")
      configuration.version_finder = ->(_request) { "9" }

      expect(described_class.new.find(request_double(path: "/v5/widgets"))).to eq("9")
    end

    it "is given the request, so it can decide from anything on it" do
      seen = nil
      configuration.version_finder = lambda do |request|
        seen = request
        "1"
      end
      request = request_double

      described_class.new.find(request)

      expect(seen).to equal(request)
    end
  end

  describe "falling back to the controller's declared versions" do
    # This is the path a Rails app that declares `version ["v2"], only: [:show]`
    # relies on: the caller sends no version at all and still has to be
    # authorized against something.
    before do
      stub_const("WidgetsController", Class.new do
        def self.versions(_action)
          %w[v7 v8]
        end
      end)
    end

    def rails_request(controller: "widgets", action: "show")
      double("request", path: "/widgets/1", params: {}, path_parameters: { controller: controller, action: action })
    end

    it "uses the first version the routed controller declares for the action" do
      pending(
        "BUG: version_from_controller calls `versions.values` on the Array that Versioned.versions returns. " \
        "The resulting NoMethodError is a NameError, so the method's own `rescue NameError` swallows it and " \
        "this fallback silently never fires."
      )

      with_fake_rails do
        expect(described_class.new.find(rails_request)).to eq("7")
      end
    end

    it "does not raise when the controller declares versions" do
      # Whatever the fallback resolves to, it runs on the authorization path of
      # every request that names no version, so it must never raise.
      with_fake_rails do
        expect { described_class.new.find(rails_request) }.not_to raise_error
      end
    end

    it "is not consulted when the request already names a version" do
      with_fake_rails do
        request = double(
          "request",
          path: "/v5/widgets/1",
          params: {},
          path_parameters: { controller: "widgets", action: "show" }
        )

        expect(described_class.new.find(request)).to eq("5")
      end
    end

    it "returns nil when the controller declares no versions for the action" do
      stub_const("WidgetsController", Class.new do
        def self.versions(_action)
          []
        end
      end)

      with_fake_rails do
        expect(described_class.new.find(rails_request)).to be_nil
      end
    end

    it "returns nil when the controller does not use the versioning concern" do
      stub_const("WidgetsController", Class.new)

      with_fake_rails do
        expect(described_class.new.find(rails_request)).to be_nil
      end
    end

    it "returns nil when the route has no controller or action" do
      with_fake_rails do
        request = double("request", path: "/", params: {}, path_parameters: {})

        expect(described_class.new.find(request)).to be_nil
      end
    end

    # A route can name a controller that does not exist (an engine that failed
    # to mount, a typo in a legacy route). Every response goes through here, so
    # that must not become a NameError on the request's hot path.
    it "returns nil rather than raising when the controller class is missing" do
      with_fake_rails do
        result = nil
        expect { result = described_class.new.find(rails_request(controller: "ghosts")) }.not_to raise_error
        expect(result).to be_nil
      end
    end

    it "returns nil for a request that has no routing information at all" do
      with_fake_rails do
        expect(described_class.new.find(request_double)).to be_nil
      end
    end
  end
end
# rubocop:enable Metrics/BlockLength
