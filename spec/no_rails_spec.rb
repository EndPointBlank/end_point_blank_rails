# frozen_string_literal: true

require "spec_helper"

# Proves the framework-agnostic core (everything except lib/end_point_blank/rails/*,
# commands/endpoint_update.rb, commands/route_pattern_finder.rb) works with ::Rails
# undefined, as it would in a plain Ruby / Sinatra host application.
#
# The gem's Writer classes (RequestWriter, ExceptionWriter, LogWriter) build their
# payload via ActionDispatch::Request, and ResponseWriter/EnvStore reach for
# ::Rack::Request; neither `actionpack` nor `rack` is a declared dependency of this
# gem (nor loaded in this spec environment), so those classes are stubbed at their
# `.write` boundary here. That keeps this spec focused on what Task 3 is actually
# verifying -- that EndPointBlank::Middleware::Rack::ReportInteraction's own control
# flow (EnvStore bookkeeping, exception handling, EndPointBlank.logger calls) never
# reaches for ::Rails -- rather than on an unrelated, pre-existing packaging gap.
NO_RAILS_SPEC_CONFIG_IVARS = %i[@client_id @client_secret @base_url @log_base_url @app_name @logger].freeze

# rubocop:disable Metrics/BlockLength
RSpec.describe "EndPointBlank core without ::Rails" do
  around do |example|
    config = EndPointBlank::Configuration.instance
    original = NO_RAILS_SPEC_CONFIG_IVARS.each_with_object({}) { |k, h| h[k] = config.instance_variable_get(k) }
    EndPointBlank.instance_variable_set(:@default_logger, nil)

    example.run

    NO_RAILS_SPEC_CONFIG_IVARS.each { |k| config.instance_variable_set(k, original[k]) }
    EndPointBlank.instance_variable_set(:@default_logger, nil)
  end

  before do
    NO_RAILS_SPEC_CONFIG_IVARS.each { |k| EndPointBlank::Configuration.instance.instance_variable_set(k, nil) }
  end

  it "confirms ::Rails is not defined in this spec environment (sanity check)" do
    expect(defined?(::Rails)).to be_falsey
  end

  it "configures the client without ::Rails defined" do
    expect do
      EndPointBlank.configure do |c|
        c.client_id = "cid"
        c.client_secret = "sec"
        c.base_url = "https://example.test"
      end
    end.not_to raise_error

    expect(EndPointBlank::Configuration.instance.client_id).to eq("cid")
    expect(EndPointBlank::Configuration.instance.base_url).to eq("https://example.test")
  end

  it "defaults EndPointBlank.logger to a stdout Logger with ::Rails undefined" do
    expect(EndPointBlank.logger).to be_a(::Logger)
  end

  describe "Middleware::Rack::ReportInteraction" do
    let(:env) { { "REQUEST_METHOD" => "GET", "PATH_INFO" => "/health", "HTTP_ACCEPT" => "application/json" } }

    before do
      # Writers reach ActionDispatch::Request / ::Rack::Request, neither of which
      # this gem depends on or loads; stubbing them isolates the middleware's own
      # (Rails-free) control flow, which is what this spec is proving out.
      allow(EndPointBlank::Writers::RequestWriter).to receive(:write)
      allow(EndPointBlank::Writers::ResponseWriter).to receive(:write)
      allow(EndPointBlank::Writers::ExceptionWriter).to receive(:write)
    end

    it "runs a full request/response cycle without raising any Rails-related error" do
      app = ->(_env) { [200, {}, ["ok"]] }
      middleware = EndPointBlank::Middleware::Rack::ReportInteraction.new(app)

      result = nil
      expect { result = middleware.call(env) }.not_to raise_error

      expect(result).to eq([200, {}, ["ok"]])
      expect(EndPointBlank::Writers::RequestWriter).to have_received(:write)
      expect(EndPointBlank::Writers::ResponseWriter)
        .to have_received(:write).with(status: 200, headers: { "Accept" => "application/json" }, body: ["ok"])
    end

    it "reports and re-raises a downstream exception without a Rails-related error" do
      boom = RuntimeError.new("kaboom")
      app = ->(_env) { raise boom }
      middleware = EndPointBlank::Middleware::Rack::ReportInteraction.new(app)

      expect { middleware.call(env) }.to raise_error(RuntimeError, "kaboom")

      expect(EndPointBlank::Writers::ExceptionWriter).to have_received(:write).with(boom)
      expect(EndPointBlank::Writers::ResponseWriter).to have_received(:write).with(
        status: 500, headers: { "Accept" => "application/json" }, body: "RuntimeError: kaboom"
      )
    end
  end
end
# rubocop:enable Metrics/BlockLength
