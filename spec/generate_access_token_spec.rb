# frozen_string_literal: true

require "spec_helper"
require "end_point_blank/commands/generate_access_token"

RSpec.describe EndPointBlank::Commands::GenerateAccessToken do
  let(:logger) { double("logger", error: nil, warn: nil, info: nil) }
  let(:rails_double) { double("Rails", logger: logger) }
  let(:configuration) { EndPointBlank::Configuration.instance }

  before do
    stub_const("Rails", rails_double)
    configuration.client_id = "id"
    configuration.client_secret = "secret"
  end

  it "passes explicit connect and read timeouts to Excon" do
    allow(Excon).to receive(:post).and_return(double(status: 200, body: "{}"))

    described_class.token("host.example.com")

    expect(Excon).to have_received(:post).with(
      configuration.access_token_url,
      hash_including(connect_timeout: EndPointBlank::Commands::Http::CONNECT_TIMEOUT,
                      read_timeout: EndPointBlank::Commands::Http::READ_TIMEOUT)
    )
  end

  it "does not raise when Excon times out" do
    allow(Excon).to receive(:post).and_raise(Excon::Error::Timeout.new("timed out"))

    result = nil
    expect { result = described_class.token("host.example.com") }.not_to raise_error
    expect(result).to be_nil
  end
end
