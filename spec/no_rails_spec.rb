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

  it "confirms ::ActionDispatch is not defined in this spec environment (sanity check)" do
    expect(defined?(::ActionDispatch)).to be_falsey
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

  # Unlike the middleware spec above (which stubs the Writers' `.write` boundary),
  # these specs exercise the *real* RequestWriter/LogWriter/ExceptionWriter
  # payload-building code against a plain Rack env, with ::Rails and
  # ::ActionDispatch both undefined. Each Writer Singleton's `.write` also
  # spins up background threads that drain a queue by POSTing (via
  # EndPointBlank::Commands::Http, which wraps excon) -- that HTTP egress is
  # stubbed at the `#enqueue` boundary instead of let asynchronously racing
  # against example teardown, since what's under test here is the
  # synchronous, framework-agnostic payload-building path, not the
  # (unrelated, already-covered) background delivery mechanics.
  describe "Writers building a real payload from a plain Rack env" do
    let(:env) do
      {
        "action_dispatch.request_id" => "abc-123",
        "REQUEST_METHOD" => "GET",
        "PATH_INFO" => "/x",
        "SERVER_NAME" => "example.test",
        "SERVER_PORT" => "80",
        "rack.input" => StringIO.new("")
        # No "puma.config" entry here: SessionConfiguration.env_name is
        # framework-agnostic and nil-safe, so payload building must complete
        # without one (this is the Sinatra/plain-Rack regression case).
      }
    end

    before { EndPointBlank::Rack::EnvStore.set(env) }
    after { EndPointBlank::Rack::EnvStore.clear }

    it "builds a RequestWriter payload from ::Rack::Request, without ActionDispatch" do
      payload = nil
      expect { payload = EndPointBlank::Writers::RequestWriter.instance.payload }.not_to raise_error

      expect(payload[:uuid]).to eq("abc-123")
      expect(payload[:http_method]).to eq("GET")
      expect(payload[:path]).to eq("/x")
    end

    it "writes a real RequestWriter payload without raising (HTTP egress stubbed)" do
      writer = EndPointBlank::Writers::RequestWriter.instance
      enqueued = nil
      allow(writer).to receive(:enqueue) { |payload| enqueued = payload }

      expect { EndPointBlank::Writers::RequestWriter.write }.not_to raise_error

      expect(enqueued[:uuid]).to eq("abc-123")
      expect(enqueued[:http_method]).to eq("GET")
      expect(enqueued[:path]).to eq("/x")
    end

    it "builds a LogWriter payload carrying the request id from the Rack env, without ActionDispatch" do
      payload = nil
      expect do
        payload = EndPointBlank::Writers::LogWriter.instance.payload(message: "hi", level: :info, data: {})
      end.not_to raise_error

      expect(payload[:uuid]).to eq("abc-123")
    end

    it "writes a real LogWriter payload without raising (HTTP egress stubbed)" do
      writer = EndPointBlank::Writers::LogWriter.instance
      enqueued = nil
      allow(writer).to receive(:enqueue) { |payload| enqueued = payload }

      expect { EndPointBlank::Writers::LogWriter.write("hi", :info) }.not_to raise_error

      expect(enqueued[:uuid]).to eq("abc-123")
    end

    it "builds an ExceptionWriter payload carrying the request id from the Rack env, without ActionDispatch" do
      exception = RuntimeError.new("boom")
      payload = nil
      expect { payload = EndPointBlank::Writers::ExceptionWriter.instance.payload(exception) }.not_to raise_error

      expect(payload[:uuid]).to eq("abc-123")
    end

    it "writes a real ExceptionWriter payload without raising (HTTP egress stubbed)" do
      writer = EndPointBlank::Writers::ExceptionWriter.instance
      enqueued = nil
      allow(writer).to receive(:enqueue) { |payload| enqueued = payload }

      expect { EndPointBlank::Writers::ExceptionWriter.write(RuntimeError.new("boom")) }.not_to raise_error

      expect(enqueued[:uuid]).to eq("abc-123")
    end
  end
end
# rubocop:enable Metrics/BlockLength
