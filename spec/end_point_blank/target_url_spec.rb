# frozen_string_literal: true

require "spec_helper"

# rubocop:disable Metrics/BlockLength
RSpec.describe EndPointBlank::TargetUrl do
  it "keeps scheme, host, port and path, and drops userinfo, query and fragment" do
    expect(described_class.strip("https://u:p@api.example.test:8443/orders?k=v#f"))
      .to eq("https://api.example.test:8443/orders")
  end

  it "accepts an uppercase HTTPS scheme and answers it lowercased" do
    expect(described_class.strip("HTTPS://api.example.test/orders")).to eq("https://api.example.test/orders")
  end

  # Matches intake's BaseUrl.normalize, so two spellings of one host share
  # one cache entry and one mint. The path keeps its case.
  it "lowercases the host" do
    expect(described_class.strip("http://API.Example.TEST/Orders")).to eq("http://api.example.test/Orders")
  end

  # sc-1469: Ruby parses these with a scheme-specific class whose parts do
  # not rebuild into "scheme://host/path" -- URI::FTP's path has no leading
  # slash, so this used to answer "ftp://hx". No provider is reached over
  # them, so they are refused like any unparseable URL.
  it "refuses any scheme other than http or https" do
    ["ftp://h:21/x", "ftp://h/x", "mailto:someone@example.test", "ws://h/x", "file:///etc/passwd"].each do |url|
      expect(described_class.strip(url)).to be_nil, "expected #{url} to be refused"
    end
  end

  describe "the port" do
    it "is dropped when it is the scheme's default" do
      expect(described_class.strip("http://h:80/x")).to eq("http://h/x")
      expect(described_class.strip("https://h:443/x")).to eq("https://h/x")
    end

    it "is kept when it is another scheme's default" do
      expect(described_class.strip("http://h:443/x")).to eq("http://h:443/x")
    end

    it "is kept after an IPv6 host, which keeps its brackets" do
      expect(described_class.strip("https://[::1]:8443/x")).to eq("https://[::1]:8443/x")
    end

    it "falls back to the default when it is empty" do
      expect(described_class.strip("http://h:/x")).to eq("http://h/x")
    end

    # intake's BaseUrl refuses these, so asking would only cost a request.
    it "is refused outside 1..65535" do
      ["http://h:0/x", "http://h:65536/x"].each do |url|
        expect(described_class.strip(url)).to be_nil, "expected #{url} to be refused"
      end
      expect(described_class.strip("http://h:65535/x")).to eq("http://h:65535/x")
      expect(described_class.strip("http://h:1/x")).to eq("http://h:1/x")
    end
  end
end
# rubocop:enable Metrics/BlockLength
