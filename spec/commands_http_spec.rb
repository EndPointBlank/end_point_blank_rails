# frozen_string_literal: true

require "spec_helper"
require "end_point_blank/commands/http"

RSpec.describe EndPointBlank::Commands::Http do
  let(:logger) { double("logger", error: nil, warn: nil, info: nil) }

  before do
    allow(EndPointBlank).to receive(:logger).and_return(logger)
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

  # sc-1463: intake will record the oldest SDK version seen per credential,
  # which gates moving an organization to another intake.
  describe "x-epb-sdk" do
    it "names this SDK and its version" do
      expect(described_class.sdk_header).to eq("ruby/#{EndPointBlank::VERSION}")
    end

    it "is sent on every post, alongside the authorization header" do
      allow(Excon).to receive(:post).and_return(double(status: 200))

      described_class.post("http://example.test", "Basic abc", { a: 1 })

      expect(Excon).to have_received(:post).with(
        "http://example.test",
        hash_including(headers: hash_including("x-epb-sdk" => "ruby/#{EndPointBlank::VERSION}",
                                               "Authorization" => "Basic abc"))
      )
    end

    it "is sent when minting an access token and when sending an endpoint update" do
      sent = []
      allow(Excon).to receive(:post) do |url, options|
        sent << [url, options[:headers]["x-epb-sdk"]]
        double(status: 500, body: "{}")
      end
      configuration = EndPointBlank::Configuration.instance
      allow(configuration).to receive(:client_id).and_return("cid")
      allow(configuration).to receive(:client_secret).and_return("csecret")

      EndPointBlank::Commands::GenerateAccessToken.token_result("https://target.example.test")
      EndPointBlank::Commands::EndpointUpdate.new.write({ application: "a", environment: "e" })

      expect(sent).to eq([
        [configuration.access_token_url, "ruby/#{EndPointBlank::VERSION}"],
        [configuration.endpoint_update_url, "ruby/#{EndPointBlank::VERSION}"]
      ])
    end
  end
end
