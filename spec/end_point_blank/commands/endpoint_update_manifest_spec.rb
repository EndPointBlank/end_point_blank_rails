# frozen_string_literal: true

require "spec_helper"
require "end_point_blank/commands/endpoint_update"

# The manifest this builds is what the portal shows a provider as "your API".
# A route that silently drops out of it looks to them like an endpoint that
# vanished on deploy.
#
# A real (named) module, because the application name is derived from the
# application class's parent module name.
module EndpointUpdateManifestSpec
  class Application
    attr_reader :config, :routes

    def initialize(config, routes)
      @config = config
      @routes = routes
    end
  end
end

# rubocop:disable Metrics/BlockLength
RSpec.describe "EndPointBlank::Commands::EndpointUpdate building the manifest" do
  let(:configuration) { EndPointBlank::Configuration.instance }
  let(:logger) { double("logger", info: nil, error: nil, warn: nil) }
  let(:updater) { EndPointBlank::Commands::EndpointUpdate.new }

  let(:full_config) { Struct.new(:force_ssl, :host, :port).new(false, "api.example.test", 3000) }

  around do |example|
    original = configuration.application_version

    example.run

    configuration.application_version = original
  end

  before do
    allow(EndPointBlank).to receive(:logger).and_return(logger)
    configuration.client_id = "cid"
    configuration.client_secret = "csecret"
    stub_const("WidgetsController", versioned_controller(%w[v1 v2]))
  end

  def versioned_controller(versions)
    Class.new do
      define_singleton_method(:versions) { |_action| versions }
    end
  end

  def route(path:, verb: "GET", controller: "widgets", action: "index")
    defaults = { controller: controller, action: action }
    double("route", defaults: defaults, verb: verb, path: double("path", spec: path))
  end

  def application(routes, config: full_config)
    EndpointUpdateManifestSpec::Application.new(config, double("routes", routes: routes))
  end

  describe "the endpoint list" do
    it "reports each versioned route's path, verb, and declared versions" do
      with_fake_rails(application: application([route(path: "/widgets(.:format)")])) do
        expect(updater.application_info[:endpoints]).to eq(
          [{ path: "/widgets", http_method: "GET", endpoint_versions: %w[v1 v2] }]
        )
      end
    end

    it "strips optional segments so a route reports the same path it authorizes under" do
      with_fake_rails(application: application([route(path: "/widgets/:id(.:format)")])) do
        expect(updater.application_info[:endpoints].first[:path]).to eq("/widgets/:id")
      end
    end

    it "leaves out routes the application does not version" do
      stub_const("PlainController", versioned_controller([]))
      routes = [route(path: "/widgets(.:format)"), route(path: "/plain", controller: "plain")]

      with_fake_rails(application: application(routes)) do
        paths = updater.application_info[:endpoints].map { |endpoint| endpoint[:path] }

        expect(paths).to eq(["/widgets"])
      end
    end

    it "leaves out a controller that does not use the versioning concern" do
      stub_const("BareController", Class.new)
      routes = [route(path: "/bare", controller: "bare")]

      with_fake_rails(application: application(routes)) do
        expect(updater.application_info[:endpoints]).to be_empty
      end
    end

    it "leaves out routes with no controller or action, such as mounted engines" do
      routes = [route(path: "/engine", controller: nil), route(path: "/other", action: nil)]

      with_fake_rails(application: application(routes)) do
        expect(updater.application_info[:endpoints]).to be_empty
      end
    end

    # Rails' own internal routes (ActiveStorage, mailer previews) are not the
    # provider's API and would be noise in their portal.
    it "leaves out Rails' internal routes" do
      stub_const("RailsInternalController", versioned_controller(%w[v1]))
      routes = [route(path: "/rails/active_storage/blobs", controller: "rails_internal")]

      with_fake_rails(application: application(routes)) do
        expect(updater.application_info[:endpoints]).to be_empty
      end
    end

    it "reports a route that answers two verbs once per verb" do
      routes = [route(path: "/widgets(.:format)", verb: "GET"), route(path: "/widgets(.:format)", verb: "POST")]

      with_fake_rails(application: application(routes)) do
        verbs = updater.application_info[:endpoints].map { |endpoint| endpoint[:http_method] }

        expect(verbs).to contain_exactly("GET", "POST")
      end
    end

    # Rails emits one route per format/constraint variant; without dedup the
    # same endpoint would be listed several times.
    it "reports duplicate route entries only once" do
      routes = [route(path: "/widgets(.:format)"), route(path: "/widgets(.:format)")]

      with_fake_rails(application: application(routes)) do
        expect(updater.application_info[:endpoints].size).to eq(1)
      end
    end
  end

  describe "the application metadata" do
    it "names the application after the Rails application's namespace" do
      with_fake_rails(application: application([])) do
        expect(updater.application_info[:application]).to eq("endpoint_update_manifest_spec")
      end
    end

    it "reports the environment the application is running in" do
      with_fake_rails(application: application([]), env: "staging") do
        expect(updater.application_info[:environment]).to eq("staging")
      end
    end

    it "reports the version of this client library" do
      with_fake_rails(application: application([])) do
        expect(updater.application_info[:lib_version]).to eq(EndPointBlank::VERSION)
      end
    end

    it "reports the configured application version" do
      configuration.application_version = "2026.08.01"

      with_fake_rails(application: application([])) do
        expect(updater.application_info[:app_version]).to eq("2026.08.01")
      end
    end

    it "reports no application version when the host application has not set one" do
      configuration.application_version = nil

      with_fake_rails(application: application([])) do
        expect(updater.application_info[:app_version]).to be_nil
      end
    end
  end

  describe "the hostname" do
    it "combines the configured host with a non-standard port" do
      with_fake_rails(application: application([])) do
        expect(updater.application_info[:hostname]).to eq("api.example.test:3000")
      end
    end

    it "omits the port when the application serves on the default HTTP port" do
      config = Struct.new(:force_ssl, :host, :port).new(false, "api.example.test", 80)

      with_fake_rails(application: application([], config: config)) do
        expect(updater.application_info[:hostname]).to eq("api.example.test")
      end
    end

    it "omits the port when the application serves on the default HTTPS port" do
      config = Struct.new(:force_ssl, :host, :port).new(true, "api.example.test", 443)

      with_fake_rails(application: application([], config: config)) do
        expect(updater.application_info[:hostname]).to eq("api.example.test")
      end
    end

    it "falls back to localhost when the application declares no host" do
      config = Struct.new(:force_ssl).new(false)

      with_fake_rails(application: application([], config: config)) do
        expect(updater.application_info[:hostname]).to eq("localhost")
      end
    end

    # Most Rails apps never set config.host, but almost all of them set the
    # mailer's default host -- it is the only place the app's public name is
    # normally written down.
    it "falls back to the mailer's default host when the application declares none" do
      config = Struct.new(:force_ssl).new(false)
      stub_const("ActionMailer::Base", double("mailer", default_url_options: { host: "mail.example.test" }))

      with_fake_rails(application: application([], config: config)) do
        expect(updater.application_info[:hostname]).to eq("mail.example.test")
      end
    end
  end

  describe "sending the manifest" do
    it "posts the manifest it just built" do
      allow(Excon).to receive(:post).and_return(double("response", status: 200, body: "ok"))

      with_fake_rails(application: application([route(path: "/widgets(.:format)")])) do
        EndPointBlank::Commands::EndpointUpdate.update
      end

      expect(Excon).to have_received(:post).with(
        configuration.endpoint_update_url,
        hash_including(body: include('"path":"/widgets"'))
      )
    end

    it "logs a rejected manifest rather than failing the deploy" do
      allow(Excon).to receive(:post).and_return(double("response", status: 422, body: "unprocessable"))

      with_fake_rails(application: application([])) do
        expect { EndPointBlank::Commands::EndpointUpdate.update }.not_to raise_error
      end

      expect(logger).to have_received(:error).with(/422/)
    end
  end
end
# rubocop:enable Metrics/BlockLength
