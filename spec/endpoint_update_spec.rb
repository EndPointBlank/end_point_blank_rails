# frozen_string_literal: true

require "spec_helper"
require "end_point_blank/commands/endpoint_update"

RSpec.describe EndPointBlank::Commands::EndpointUpdate do
  let(:logger) { double("logger", error: nil, warn: nil, info: nil) }
  let(:rails_double) { double("Rails", logger: logger) }
  let(:configuration) { EndPointBlank::Configuration.instance }
  let(:updater) { described_class.new }
  let(:data) { { application: "app", environment: "test", app_version: "1.0" } }

  before do
    stub_const("Rails", rails_double)
    configuration.client_id = "id"
    configuration.client_secret = "secret"
  end

  it "passes explicit connect and read timeouts to Excon" do
    allow(Excon).to receive(:post).and_return(double(status: 200, body: "ok"))

    updater.write(data)

    expect(Excon).to have_received(:post).with(
      configuration.endpoint_update_url,
      hash_including(connect_timeout: EndPointBlank::Commands::Http::CONNECT_TIMEOUT,
                      read_timeout: EndPointBlank::Commands::Http::READ_TIMEOUT)
    )
  end

  it "does not raise when Excon times out (gap: old rescue clause referenced a non-existent constant)" do
    allow(Excon).to receive(:post).and_raise(Excon::Error::Timeout.new("timed out"))

    expect { updater.write(data) }.not_to raise_error
    expect(logger).to have_received(:warn)
  end
end
