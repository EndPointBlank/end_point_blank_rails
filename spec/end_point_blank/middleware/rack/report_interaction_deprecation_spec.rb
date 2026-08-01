# frozen_string_literal: true

require "spec_helper"

# End-to-end through the Rack middleware: the point is that a provider writes
# no code, so what matters is that a response acquires the headers purely
# because the portal deprecated the version.
RSpec.describe EndPointBlank::Middleware::Rack::ReportInteraction do
  let(:downstream) { ->(_env) { [200, { "Content-Type" => "application/json" }, ["{}"]] } }
  let(:middleware) { described_class.new(downstream) }
  let(:env) { ::Rack::MockRequest.env_for("/things") }

  before do
    allow(EndPointBlank::Writers::RequestWriter).to receive(:write)
    allow(EndPointBlank::Writers::ResponseWriter).to receive(:write)
  end

  after { EndPointBlank::Rack::EnvStore.clear }

  it "adds both headers when the version is deprecated with a date" do
    EndPointBlank::Rack::EnvStore.set_deprecation(
      "deprecated_at" => "2026-01-01T00:00:00Z",
      "sunset_at" => "2026-11-11T11:11:11Z"
    )

    _status, headers, _body = middleware.call(env)

    expect(headers["Deprecation"]).to eq("@1767225600")
    expect(headers["Sunset"]).to eq("Wed, 11 Nov 2026 11:11:11 GMT")
  end

  it "adds Deprecation alone when no sunset date is set" do
    EndPointBlank::Rack::EnvStore.set_deprecation("deprecated_at" => "2026-01-01T00:00:00Z")

    _status, headers, _body = middleware.call(env)

    expect(headers).to have_key("Deprecation")
    expect(headers).not_to have_key("Sunset")
  end

  it "adds nothing when the version is not deprecated" do
    _status, headers, _body = middleware.call(env)

    expect(headers).not_to have_key("Deprecation")
    expect(headers).not_to have_key("Sunset")
  end

  it "leaves the downstream response otherwise untouched" do
    EndPointBlank::Rack::EnvStore.set_deprecation("deprecated_at" => "2026-01-01T00:00:00Z")

    status, headers, body = middleware.call(env)

    expect(status).to eq(200)
    expect(headers["Content-Type"]).to eq("application/json")
    expect(body).to eq(["{}"])
  end

  it "does not raise into the response path when the block is malformed" do
    # A bad header is a bug; a 500 on a request that already succeeded is an
    # outage. This runs on every authorized response.
    EndPointBlank::Rack::EnvStore.set_deprecation("deprecated_at" => "not a date")

    expect { middleware.call(env) }.not_to raise_error
  end
end
