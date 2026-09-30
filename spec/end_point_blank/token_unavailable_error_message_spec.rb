# frozen_string_literal: true

require "spec_helper"

# The message is what reaches logs and error reporting, and the caller controls
# the URL in it, so it must never repeat the URL's userinfo, query or fragment
# (sc-1469 review on js#54).
RSpec.describe EndPointBlank::TokenUnavailableError do
  let(:raw) { "https://user:hunter2@api.provider.test:8443/v1/things?api_key=s3cret#frag" }

  it "names only the scheme, host and path in its message" do
    message = described_class.new(raw).message

    expect(message).to include("for https://api.provider.test:8443/v1/things: ")
    %w[user hunter2 api_key s3cret frag].each do |secret|
      expect(message).not_to include(secret)
    end
  end

  # sc-1469 review ruling (a): the raw URL is not kept anywhere on the error.
  # Error reporters capture attributes as well as the message, and the
  # caller already has the raw value.
  it "keeps only the stripped URL on #base_url" do
    expect(described_class.new(raw).base_url).to eq("https://api.provider.test:8443/v1/things")
  end

  it "keeps an IPv6 host in brackets and drops only the default port" do
    expect(described_class.new("https://[::1]:443/v1?x=1").base_url).to eq("https://[::1]/v1")
    expect(described_class.new("http://[::1]:8080/v1#f").base_url).to eq("http://[::1]:8080/v1")
  end

  it "leaves an unparseable URL out of the message" do
    message = described_class.new("not a url ?token=s3cret").message

    expect(message).not_to include("s3cret")
    expect(message).to include("could not be parsed")
    expect(described_class.new("not a url ?token=s3cret").base_url).to be_nil
  end
end
