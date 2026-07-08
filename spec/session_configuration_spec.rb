# frozen_string_literal: true

require "spec_helper"

SESSION_CONFIGURATION_SPEC_ENV_KEYS = %w[
  ENDPOINTBLANK_ENV
  RACK_ENV
  APP_ENV
].freeze

SESSION_CONFIGURATION_SPEC_IVARS = %i[@env_name].freeze

# rubocop:disable Metrics/BlockLength
RSpec.describe EndPointBlank::SessionConfiguration do
  let(:configuration) { EndPointBlank::Configuration.instance }

  around do |example|
    original_env = SESSION_CONFIGURATION_SPEC_ENV_KEYS.each_with_object({}) { |k, h| h[k] = ENV.delete(k) }
    original_ivars = SESSION_CONFIGURATION_SPEC_IVARS.each_with_object({}) do |k, h|
      h[k] = configuration.instance_variable_get(k)
    end

    example.run

    SESSION_CONFIGURATION_SPEC_IVARS.each { |k| configuration.instance_variable_set(k, original_ivars[k]) }
    SESSION_CONFIGURATION_SPEC_ENV_KEYS.each { |k| ENV.delete(k) }
    original_env.each { |k, v| ENV[k] = v unless v.nil? }
    EndPointBlank::Rack::EnvStore.clear
  end

  before do
    SESSION_CONFIGURATION_SPEC_IVARS.each { |k| configuration.instance_variable_set(k, nil) }
    EndPointBlank::Rack::EnvStore.clear
  end

  describe ".env_name" do
    it "prefers Configuration.instance.env_name (explicit config) over everything else" do
      ENV["RACK_ENV"] = "rack-env"
      ENV["APP_ENV"] = "app-env"
      EndPointBlank.configure { |c| c.env_name = "explicit-env-name" }

      expect(described_class.env_name).to eq("explicit-env-name")
    end

    it "uses ENDPOINTBLANK_ENV (via Configuration) when explicit config is unset" do
      ENV["ENDPOINTBLANK_ENV"] = "endpointblank-env"
      ENV["RACK_ENV"] = "rack-env"
      ENV["APP_ENV"] = "app-env"

      expect(described_class.env_name).to eq("endpointblank-env")
    end

    it "uses RACK_ENV when config and ENDPOINTBLANK_ENV are unset" do
      ENV["RACK_ENV"] = "rack-env"
      ENV["APP_ENV"] = "app-env"

      expect(described_class.env_name).to eq("rack-env")
    end

    it "uses APP_ENV when config, ENDPOINTBLANK_ENV, and RACK_ENV are unset" do
      ENV["APP_ENV"] = "app-env"

      expect(described_class.env_name).to eq("app-env")
    end

    it "falls back to a Puma config in the Rack env (back-compat) when higher-precedence sources are unset" do
      EndPointBlank::Rack::EnvStore.set("puma.config" => double(options: { environment: "puma-env" }))

      expect(described_class.env_name).to eq("puma-env")
    end

    it "does not consult Puma when a higher-precedence source is set" do
      ENV["RACK_ENV"] = "rack-env"
      EndPointBlank::Rack::EnvStore.set("puma.config" => double(options: { environment: "puma-env" }))

      expect(described_class.env_name).to eq("rack-env")
    end

    it "returns 'production' without raising when there is no Rack env at all (the Sinatra/plain-Rack case)" do
      expect(EndPointBlank::Rack::EnvStore.get).to be_nil

      expect { described_class.env_name }.not_to raise_error
      expect(described_class.env_name).to eq("production")
    end

    it "returns 'production' without raising when the Rack env has no puma.config key" do
      EndPointBlank::Rack::EnvStore.set("REQUEST_METHOD" => "GET")

      expect { described_class.env_name }.not_to raise_error
      expect(described_class.env_name).to eq("production")
    end

    it "returns a String" do
      expect(described_class.env_name).to be_a(String)
    end
  end
end
# rubocop:enable Metrics/BlockLength
