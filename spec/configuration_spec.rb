# frozen_string_literal: true

require "spec_helper"

CONFIGURATION_SPEC_ENV_KEYS = %w[
  ENDPOINTBLANK_CLIENT_ID
  ENDPOINTBLANK_CLIENT_SECRET
  ENDPOINTBLANK_BASE_URL
  ENDPOINTBLANK_LOG_BASE_URL
  ENDPOINTBLANK_APP_NAME
  ENDPOINTBLANK_ENV
].freeze

CONFIGURATION_SPEC_IVARS = %i[@client_id @client_secret @base_url @log_base_url @app_name @env_name].freeze

# rubocop:disable Metrics/BlockLength
RSpec.describe EndPointBlank::Configuration do
  let(:configuration) { described_class.instance }

  around do |example|
    original_env = CONFIGURATION_SPEC_ENV_KEYS.each_with_object({}) { |k, h| h[k] = ENV.delete(k) }
    original_ivars = CONFIGURATION_SPEC_IVARS.each_with_object({}) do |k, h|
      h[k] = configuration.instance_variable_get(k)
    end

    example.run

    CONFIGURATION_SPEC_IVARS.each { |k| configuration.instance_variable_set(k, original_ivars[k]) }
    CONFIGURATION_SPEC_ENV_KEYS.each { |k| ENV.delete(k) }
    original_env.each { |k, v| ENV[k] = v unless v.nil? }
  end

  before do
    CONFIGURATION_SPEC_IVARS.each { |k| configuration.instance_variable_set(k, nil) }
  end

  describe "#client_id" do
    it "falls back to ENDPOINTBLANK_CLIENT_ID when unset" do
      ENV["ENDPOINTBLANK_CLIENT_ID"] = "env-client-id"

      expect(configuration.client_id).to eq("env-client-id")
    end

    it "prefers an explicitly configured value over the env var" do
      ENV["ENDPOINTBLANK_CLIENT_ID"] = "env-client-id"
      EndPointBlank.configure { |c| c.client_id = "explicit-client-id" }

      expect(configuration.client_id).to eq("explicit-client-id")
    end

    it "returns nil when neither is set" do
      expect(configuration.client_id).to be_nil
    end
  end

  describe "#client_secret" do
    it "falls back to ENDPOINTBLANK_CLIENT_SECRET when unset" do
      ENV["ENDPOINTBLANK_CLIENT_SECRET"] = "env-client-secret"

      expect(configuration.client_secret).to eq("env-client-secret")
    end

    it "prefers an explicitly configured value over the env var" do
      ENV["ENDPOINTBLANK_CLIENT_SECRET"] = "env-client-secret"
      EndPointBlank.configure { |c| c.client_secret = "explicit-client-secret" }

      expect(configuration.client_secret).to eq("explicit-client-secret")
    end

    it "returns nil when neither is set" do
      expect(configuration.client_secret).to be_nil
    end
  end

  describe "#base_url" do
    it "falls back to ENDPOINTBLANK_BASE_URL when unset" do
      ENV["ENDPOINTBLANK_BASE_URL"] = "https://env.example.com"

      expect(configuration.base_url).to eq("https://env.example.com")
    end

    it "prefers an explicitly configured value over the env var" do
      ENV["ENDPOINTBLANK_BASE_URL"] = "https://env.example.com"
      EndPointBlank.configure { |c| c.base_url = "https://explicit.example.com" }

      expect(configuration.base_url).to eq("https://explicit.example.com")
    end

    it "defaults to https://in.endpointblank.com when neither is set" do
      expect(configuration.base_url).to eq("https://in.endpointblank.com")
    end
  end

  describe "#log_base_url" do
    it "falls back to ENDPOINTBLANK_LOG_BASE_URL when unset" do
      ENV["ENDPOINTBLANK_LOG_BASE_URL"] = "https://env-log.example.com"

      expect(configuration.log_base_url).to eq("https://env-log.example.com")
    end

    it "prefers an explicitly configured value over the env var" do
      ENV["ENDPOINTBLANK_LOG_BASE_URL"] = "https://env-log.example.com"
      EndPointBlank.configure { |c| c.log_base_url = "https://explicit-log.example.com" }

      expect(configuration.log_base_url).to eq("https://explicit-log.example.com")
    end

    it "defaults to https://log.endpointblank.com when neither is set" do
      expect(configuration.log_base_url).to eq("https://log.endpointblank.com")
    end
  end

  describe "#app_name" do
    it "falls back to ENDPOINTBLANK_APP_NAME when unset and ::Rails is undefined" do
      expect(defined?(::Rails)).to be_falsey
      ENV["ENDPOINTBLANK_APP_NAME"] = "env-app-name"

      expect(configuration.app_name).to eq("env-app-name")
    end

    it "prefers an explicitly configured value over the env var" do
      ENV["ENDPOINTBLANK_APP_NAME"] = "env-app-name"
      EndPointBlank.configure { |c| c.app_name = "explicit-app-name" }

      expect(configuration.app_name).to eq("explicit-app-name")
    end

    it "returns nil without raising when unset and ::Rails is undefined" do
      expect(defined?(::Rails)).to be_falsey

      expect { configuration.app_name }.not_to raise_error
      expect(configuration.app_name).to be_nil
    end

    it "derives a name from the Rails application when nothing else is set" do
      with_fake_rails(application: double("application", name: "MyApp::Application")) do
        expect(configuration.app_name).to include("my_app")
      end
    end

    it "still prefers the env var over the Rails application name" do
      ENV["ENDPOINTBLANK_APP_NAME"] = "env-app-name"

      with_fake_rails(application: double("application", name: "MyApp::Application")) do
        expect(configuration.app_name).to eq("env-app-name")
      end
    end
  end

  describe "#env_name" do
    it "falls back to ENDPOINTBLANK_ENV when unset" do
      ENV["ENDPOINTBLANK_ENV"] = "env-name-from-env"

      expect(configuration.env_name).to eq("env-name-from-env")
    end

    it "prefers an explicitly configured value over the env var" do
      ENV["ENDPOINTBLANK_ENV"] = "env-name-from-env"
      EndPointBlank.configure { |c| c.env_name = "explicit-env-name" }

      expect(configuration.env_name).to eq("explicit-env-name")
    end

    it "returns nil when neither is set" do
      expect(configuration.env_name).to be_nil
    end
  end
end
# rubocop:enable Metrics/BlockLength
