# frozen_string_literal: true

require "spec_helper"
require "end_point_blank/commands/generate_access_token"

# Proves EndPointBlank::Commands::GenerateAccessToken.token symbolizes the
# response body's keys without reaching for ActiveSupport's
# Hash#symbolize_keys, which raises NoMethodError (silently rescued by the
# method's own broad `rescue => e`, so a plain Ruby / Sinatra host app would
# see the token cache simply never populate, with no visible error) when
# ActiveSupport is not loaded.
# rubocop:disable Metrics/BlockLength
RSpec.describe "EndPointBlank::Commands::GenerateAccessToken without ActiveSupport" do
  let(:logger) { double("logger", error: nil, warn: nil, info: nil) }
  let(:configuration) { EndPointBlank::Configuration.instance }

  before do
    allow(EndPointBlank).to receive(:logger).and_return(logger)
    configuration.client_id = "id"
    configuration.client_secret = "secret"
  end

  it "confirms ActiveSupport is not loaded in this spec environment (sanity check)" do
    expect(defined?(ActiveSupport)).to be_nil
  end

  it "returns a symbol-keyed Hash from a JSON String response body, with no NoMethodError" do
    allow(Excon).to receive(:post).and_return(
      double(status: 200, body: '{"token":"abc123","expired_at":"2099-01-01T00:00:00Z"}')
    )

    result = nil
    expect { result = EndPointBlank::Commands::GenerateAccessToken.token("host.example.com") }.not_to raise_error

    expect(result).to eq(token: "abc123", expired_at: "2099-01-01T00:00:00Z")
  end

  it "returns a symbol-keyed Hash when the response body is already a Hash, with no NoMethodError" do
    allow(Excon).to receive(:post).and_return(
      double(status: 200, body: { "token" => "def456", "expired_at" => "2099-01-01T00:00:00Z" })
    )

    result = nil
    expect { result = EndPointBlank::Commands::GenerateAccessToken.token("host.example.com") }.not_to raise_error

    expect(result).to eq(token: "def456", expired_at: "2099-01-01T00:00:00Z")
  end
end
# rubocop:enable Metrics/BlockLength
