# frozen_string_literal: true

require "spec_helper"

RSpec.describe EndPointBlank::TargetUrl do
  it "keeps scheme, host, port and path, and drops userinfo, query and fragment" do
    expect(described_class.strip("https://u:p@api.example.test:8443/orders?k=v#f"))
      .to eq("https://api.example.test:8443/orders")
  end

  it "accepts an uppercase HTTPS scheme and answers it lowercased" do
    expect(described_class.strip("HTTPS://api.example.test/orders")).to eq("https://api.example.test/orders")
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
end
