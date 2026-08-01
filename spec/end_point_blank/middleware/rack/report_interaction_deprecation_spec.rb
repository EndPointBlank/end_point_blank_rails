# frozen_string_literal: true

require "spec_helper"

# End-to-end through the Rack middleware: the point is that a provider writes
# no code, so what matters is that a response acquires the headers purely
# because the portal deprecated the version.
#
# The deprecation is set from inside the downstream app, because that is where
# it really happens — `authorize!` is a before_action, which runs inside the
# middleware. Setting it beforehand would not work, and should not: the
# middleware installs a fresh env at the top of every request, which is exactly
# what makes the value per-request rather than per-thread.
RSpec.describe EndPointBlank::Middleware::Rack::ReportInteraction do
  let(:deprecation) { nil }

  let(:downstream) do
    dep = deprecation
    lambda do |_env|
      EndPointBlank::Rack::EnvStore.set_deprecation(dep) if dep
      [200, { "Content-Type" => "application/json" }, ["{}"]]
    end
  end

  let(:middleware) { described_class.new(downstream) }
  let(:env) { ::Rack::MockRequest.env_for("/things") }

  before do
    allow(EndPointBlank::Writers::RequestWriter).to receive(:write)
    allow(EndPointBlank::Writers::ResponseWriter).to receive(:write)
  end

  after { EndPointBlank::Rack::EnvStore.clear }

  context "when the called version is deprecated with a sunset date" do
    let(:deprecation) do
      { "deprecated_at" => "2026-01-01T00:00:00Z", "sunset_at" => "2026-11-11T11:11:11Z" }
    end

    it "adds both headers" do
      _status, headers, _body = middleware.call(env)

      expect(headers["Deprecation"]).to eq("@1767225600")
      expect(headers["Sunset"]).to eq("Wed, 11 Nov 2026 11:11:11 GMT")
    end

    it "leaves the downstream response otherwise untouched" do
      status, headers, body = middleware.call(env)

      expect(status).to eq(200)
      expect(headers["Content-Type"]).to eq("application/json")
      expect(body).to eq(["{}"])
    end
  end

  context "when the version is deprecated with no date" do
    let(:deprecation) { { "deprecated_at" => "2026-01-01T00:00:00Z" } }

    it "adds Deprecation alone" do
      _status, headers, _body = middleware.call(env)

      expect(headers).to have_key("Deprecation")
      expect(headers).not_to have_key("Sunset")
    end
  end

  context "when the version is not deprecated" do
    it "adds nothing" do
      _status, headers, _body = middleware.call(env)

      expect(headers).not_to have_key("Deprecation")
      expect(headers).not_to have_key("Sunset")
    end
  end

  context "when the block is malformed" do
    let(:deprecation) { { "deprecated_at" => "not a date" } }

    it "does not raise into the response path" do
      # A bad header is a bug; a 500 on a request that already succeeded is an
      # outage. This runs on every authorized response.
      expect { middleware.call(env) }.not_to raise_error
    end
  end

  describe "request isolation on a reused thread" do
    # Puma reuses threads between requests. Holding this in a thread-local is
    # only correct while something reliably clears it; holding it in the env
    # makes it per-request by construction.
    let(:deprecation) do
      { "deprecated_at" => "2026-01-01T00:00:00Z", "sunset_at" => "2026-11-11T11:11:11Z" }
    end

    it "does not leak into the next request on the same thread" do
      _s, first_headers, _b = middleware.call(env)
      expect(first_headers).to have_key("Deprecation")

      # A second request on this same thread, whose app sets no deprecation.
      plain = described_class.new(->(_e) { [200, {}, ["{}"]] })
      _s, second_headers, _b = plain.call(::Rack::MockRequest.env_for("/other"))

      expect(second_headers).not_to have_key("Deprecation")
      expect(second_headers).not_to have_key("Sunset")
    end

    it "cannot read a value stranded by a request that never cleared" do
      # Simulate the gap the thread-local had: something set a deprecation
      # outside any middleware run, so `clear` never happened for it.
      EndPointBlank::Rack::EnvStore.set(::Rack::MockRequest.env_for("/stale"))
      EndPointBlank::Rack::EnvStore.set_deprecation("deprecated_at" => "2026-01-01T00:00:00Z")

      # A real request now arrives on the same thread. `set/1` replaces the env
      # wholesale, so the stranded value is unreachable.
      plain = described_class.new(->(_e) { [200, {}, ["{}"]] })
      _s, headers, _b = plain.call(::Rack::MockRequest.env_for("/fresh"))

      expect(headers).not_to have_key("Deprecation")
    end

    it "is a no-op outside a Rack request rather than an error" do
      EndPointBlank::Rack::EnvStore.clear

      expect do
        EndPointBlank::Rack::EnvStore.set_deprecation("deprecated_at" => "2026-01-01T00:00:00Z")
      end.not_to raise_error

      expect(EndPointBlank::Rack::EnvStore.deprecation).to be_nil
    end
  end
end
