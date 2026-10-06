# frozen_string_literal: true

require "spec_helper"

# sc-1470: a caller's credentials and cookies must never reach the provider's
# request log in EndPointBlank, whether or not a masking rule names them.
RSpec.describe "Headers the writers never send" do
  let(:env) do
    ::Rack::MockRequest.env_for(
      "/orders",
      "REQUEST_METHOD" => "POST",
      "HTTP_HOST" => "api.example.com",
      "HTTP_AUTHORIZATION" => "Basic Y2xpZW50OnNlY3JldA==",
      "HTTP_PROXY_AUTHORIZATION" => "Bearer proxy-token",
      "HTTP_COOKIE" => "session=abc",
      "HTTP_X_REQUEST_ID" => "req-abc"
    )
  end

  before { EndPointBlank::Rack::EnvStore.set(env) }
  after { EndPointBlank::Rack::EnvStore.clear }

  it "lists the credential and cookie headers, lower-cased and frozen" do
    expect(EndPointBlank::Rack::Headers::SENSITIVE_HEADERS)
      .to contain_exactly("authorization", "proxy-authorization", "cookie", "set-cookie")
    expect(EndPointBlank::Rack::Headers::SENSITIVE_HEADERS).to be_frozen
  end

  it "leaves them out of the request record" do
    headers = EndPointBlank::Writers::RequestWriter.instance.payload[:headers]

    expect(headers).to eq("Host" => "api.example.com", "X-Request-Id" => "req-abc")
  end

  it "leaves them out of the response record" do
    payload = EndPointBlank::Writers::ResponseWriter.instance.payload(status: 200, headers: {}, body: nil)

    expect(payload[:headers]).to eq("Host" => "api.example.com", "X-Request-Id" => "req-abc")
  end

  it "keeps them available to the SDK itself" do
    expect(EndPointBlank::Rack::Headers.extract).to include("Authorization" => "Basic Y2xpZW50OnNlY3JldA==")
  end

  describe ".without_sensitive" do
    it "drops every listed header in any letter case and keeps the rest" do
      headers = { "AUTHORIZATION" => "x", "set-cookie" => "a=b", "Set-Cookie" => "c=d", "Accept" => "*/*" }

      expect(EndPointBlank::Rack::Headers.without_sensitive(headers)).to eq("Accept" => "*/*")
      expect(headers.size).to eq(4)
    end

    it "answers an empty hash for nil" do
      expect(EndPointBlank::Rack::Headers.without_sensitive(nil)).to eq({})
    end
  end
end
