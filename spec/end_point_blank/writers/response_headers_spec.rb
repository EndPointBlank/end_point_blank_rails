# frozen_string_literal: true

require "spec_helper"

# sc-1627: the response record carries the response's own headers. It used to
# carry the request's, so intake's response log showed request headers.
RSpec.describe "The response record's headers" do
  let(:env) do
    ::Rack::MockRequest.env_for(
      "/orders",
      "REQUEST_METHOD" => "POST",
      "HTTP_X_API_KEY" => "caller-key",
      "HTTP_X_REQUEST_ONLY" => "from-the-request"
    )
  end

  before { EndPointBlank::Rack::EnvStore.set(env) }
  after { EndPointBlank::Rack::EnvStore.clear }

  def response_headers_for(headers)
    EndPointBlank::Writers::ResponseWriter.instance.payload(status: 201, headers:, body: nil)[:headers]
  end

  it "are the response's headers, with no request-only header" do
    headers = response_headers_for("Content-Type" => "application/json", "X-Response-Only" => "yes")

    expect(headers).to eq("Content-Type" => "application/json", "X-Response-Only" => "yes")
    expect(headers.keys.map(&:downcase)).not_to include("x-request-only", "x-api-key")
  end

  it "drop the sensitive headers in any letter case" do
    headers = response_headers_for("set-cookie" => "a=b", "Authorization" => "Bearer t", "ETag" => "\"1\"")

    expect(headers).to eq("ETag" => "\"1\"")
  end

  it "accept a Rack::Headers and join a multi-value header" do
    rack_headers = ::Rack::Headers.new
    rack_headers["content-type"] = "text/plain"
    rack_headers["vary"] = %w[Accept Origin]

    expect(response_headers_for(rack_headers)).to eq("content-type" => "text/plain", "vary" => "Accept, Origin")
  end

  it "are empty when there are none" do
    expect(response_headers_for(nil)).to eq({})
    expect(response_headers_for({})).to eq({})
  end

  describe "through the middleware" do
    let(:records) { [] }

    before do
      allow(EndPointBlank::Writers::RequestWriter).to receive(:write)
      allow(EndPointBlank::Writers::ResponseWriter).to receive(:write) do |**kwargs|
        records << EndPointBlank::Writers::ResponseWriter.instance.payload(**kwargs)
      end
    end

    it "sends the app's response headers, not the request's" do
      app = ->(_env) { [200, { "content-type" => "text/plain", "x-response-only" => "yes" }, ["ok"]] }

      EndPointBlank::Middleware::Rack::ReportInteraction.new(app).call(env)

      expect(records.last[:headers]).to eq("content-type" => "text/plain", "x-response-only" => "yes")
    end

    it "sends no headers when the app raised" do
      app = ->(_env) { raise "boom" }
      allow(EndPointBlank::Writers::ExceptionWriter).to receive(:write)

      expect { EndPointBlank::Middleware::Rack::ReportInteraction.new(app).call(env) }.to raise_error("boom")

      expect(records.last[:headers]).to eq({})
    end
  end
end
