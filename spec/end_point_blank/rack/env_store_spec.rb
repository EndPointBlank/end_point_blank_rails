# frozen_string_literal: true

require "spec_helper"

# Everything this store holds is per-request data living in a process whose
# threads are reused between requests. The property under test is therefore not
# "can it store a value" but "can one request read another request's value" —
# which is what a thread-local made possible, and what keying off the Rack env
# rules out.
RSpec.describe EndPointBlank::Rack::EnvStore do
  let(:env) { ::Rack::MockRequest.env_for("/things") }

  after { described_class.clear }

  # Both values behave identically, so the same isolation properties are
  # asserted for each rather than trusted to generalise from one.
  {
    "source_application_environment_id" => {
      set: :set_source_application_environment_id,
      get: :source_application_environment_id,
      value: "app-env-123"
    },
    "deprecation" => {
      set: :set_deprecation,
      get: :deprecation,
      value: { "deprecated_at" => "2026-01-01T00:00:00Z" }
    }
  }.each do |name, ops|
    describe name do
      it "round-trips within a request" do
        described_class.set(env)
        described_class.public_send(ops[:set], ops[:value])

        expect(described_class.public_send(ops[:get])).to eq(ops[:value])
      end

      it "is not visible to the next request on the same thread" do
        described_class.set(env)
        described_class.public_send(ops[:set], ops[:value])

        # The next request installs its own env. No clear/0 in between — that is
        # the point: isolation must not depend on cleanup running.
        described_class.set(::Rack::MockRequest.env_for("/other"))

        expect(described_class.public_send(ops[:get])).to be_nil
      end

      it "does not survive a clear" do
        described_class.set(env)
        described_class.public_send(ops[:set], ops[:value])
        described_class.clear

        expect(described_class.public_send(ops[:get])).to be_nil
      end

      it "is a no-op outside a request rather than an error" do
        described_class.clear

        expect { described_class.public_send(ops[:set], ops[:value]) }.not_to raise_error
        expect(described_class.public_send(ops[:get])).to be_nil
      end

      it "lives in the env itself, so it travels with the request" do
        described_class.set(env)
        described_class.public_send(ops[:set], ops[:value])

        # Not an implementation detail worth hiding: any middleware holding the
        # env can read it, and nothing outside the request can.
        expect(env.values).to include(ops[:value])
      end
    end
  end

  describe "the two values together" do
    it "are independent" do
      described_class.set(env)
      described_class.set_source_application_environment_id("app-env-123")

      expect(described_class.deprecation).to be_nil
      expect(described_class.source_application_environment_id).to eq("app-env-123")
    end
  end

  describe "#request" do
    it "wraps the current env" do
      described_class.set(env)
      expect(described_class.request).to be_a(::Rack::Request)
    end

    it "is nil outside a request" do
      described_class.clear
      expect(described_class.request).to be_nil
    end
  end
end
