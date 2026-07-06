# frozen_string_literal: true

require "spec_helper"
require "end_point_blank/commands/http"

RSpec.describe EndPointBlank::Commands::Http do
  let(:logger) { double("logger", error: nil, warn: nil, info: nil) }
  let(:rails_double) { double("Rails", logger: logger) }

  before do
    stub_const("Rails", rails_double)
  end

  describe "::post" do
    it "passes explicit connect and read timeouts to Excon" do
      allow(Excon).to receive(:post).and_return(double(status: 200))

      described_class.post("http://example.test", "Bearer xyz", { a: 1 })

      expect(Excon).to have_received(:post).with(
        "http://example.test",
        hash_including(connect_timeout: EndPointBlank::Commands::Http::CONNECT_TIMEOUT,
                        read_timeout: EndPointBlank::Commands::Http::READ_TIMEOUT)
      )
    end

    it "does not raise on a timeout, retries, and logs after exhausting attempts" do
      allow(Excon).to receive(:post).and_raise(Excon::Error::Timeout.new("timed out"))
      allow(described_class).to receive(:sleep)

      result = nil
      expect { result = described_class.post("http://example.test", "Bearer xyz", { a: 1 }) }
        .not_to raise_error

      expect(result).to be_nil
      expect(Excon).to have_received(:post).exactly(EndPointBlank::Commands::Http::MAX_ATTEMPTS).times
      expect(logger).to have_received(:error)
    end
  end
end
