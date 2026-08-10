# frozen_string_literal: true

require "spec_helper"

RSpec.describe EndPointBlank::BaseUrl do
  # Built by hand rather than through Rack::MockRequest, because the point of
  # this module is that it reads the env itself instead of trusting Rack's
  # (or Express's, or the servlet container's) idea of what "host" means.
  def env(overrides = {})
    {
      "rack.url_scheme" => "https",
      "SERVER_NAME" => "api.example.com",
      "SERVER_PORT" => "8443",
      "HTTP_HOST" => "API.Example.com:8443"
    }.merge(overrides)
  end

  it "resolves scheme host and port from a direct request" do
    expect(described_class.from_rack_env(env)).to eq(scheme: "https", host: "api.example.com", port: 8443)
  end

  it "omits the port when it is the scheme default" do
    resolved = described_class.from_rack_env(env("HTTP_HOST" => "api.example.com", "SERVER_PORT" => "443"))

    expect(resolved).to eq(scheme: "https", host: "api.example.com")
  end

  it "reports what the caller used, not what the process sees" do
    resolved = described_class.from_rack_env(env(
                                               "rack.url_scheme" => "http",
                                               "SERVER_PORT" => "8080",
                                               "HTTP_HOST" => "internal.svc:8080",
                                               "HTTP_X_FORWARDED_PROTO" => "https",
                                               "HTTP_X_FORWARDED_HOST" => "api.example.com",
                                               "HTTP_X_FORWARDED_PORT" => "443"
                                             ))

    expect(resolved).to eq(scheme: "https", host: "api.example.com")
  end

  it "omits the connection port once a proxy is in front" do
    # 8080 is the internal listener. The caller never saw it, so reporting it
    # would be worse than reporting nothing.
    resolved = described_class.from_rack_env(env(
                                               "rack.url_scheme" => "http",
                                               "SERVER_PORT" => "8080",
                                               "HTTP_HOST" => "api.example.com",
                                               "HTTP_X_FORWARDED_PROTO" => "https"
                                             ))

    expect(resolved).to eq(scheme: "https", host: "api.example.com")
  end

  it "takes the last forwarded hop so a caller cannot prepend its own" do
    # A proxy that appends writes its own observation last; a value the caller
    # planted arrives to the left of it.
    resolved = described_class.from_rack_env(env(
                                               "HTTP_X_FORWARDED_PROTO" => "https, http",
                                               "HTTP_X_FORWARDED_HOST" => "evil.example, api.example.com"
                                             ))

    expect(resolved[:scheme]).to eq("http")
    expect(resolved[:host]).to eq("api.example.com")
  end

  it "omits a field it cannot resolve rather than reporting null" do
    expect(described_class.from_rack_env({})).to eq({})
  end

  it "drops a host that is not shaped like a hostname" do
    resolved = described_class.from_rack_env(env("HTTP_HOST" => "api.example.com/../evil?x=1"))

    expect(resolved).not_to have_key(:host)
    expect(resolved).to eq(scheme: "https", port: 8443)
  end

  it "ignores the forwarded headers when proxy headers are not trusted" do
    # Same request as "reports what the caller used", resolved both ways, so
    # the only difference between the two expectations is the flag. Off, the
    # request is not proxied at all, so 8080 is evidence again.
    proxied = env(
      "rack.url_scheme" => "http",
      "SERVER_PORT" => "8080",
      "HTTP_HOST" => "internal.svc:8080",
      "HTTP_X_FORWARDED_PROTO" => "https",
      "HTTP_X_FORWARDED_HOST" => "api.example.com",
      "HTTP_X_FORWARDED_PORT" => "443"
    )

    expect(described_class.from_rack_env(proxied, trust_proxy_headers: true))
      .to eq(scheme: "https", host: "api.example.com")
    expect(described_class.from_rack_env(proxied, trust_proxy_headers: false))
      .to eq(scheme: "http", host: "internal.svc", port: 8080)
  end

  it "normalizes the scheme to lowercase without a trailing colon" do
    # JS's location.protocol and Node's URL#protocol both yield "https:".
    # intake never rewrites a stored row, so the first release's shape is
    # permanent -- normalize on the way out, not on the way in.
    expect(described_class.from_rack_env(env("HTTP_X_FORWARDED_PROTO" => "HTTPS"))[:scheme]).to eq("https")
    expect(described_class.from_rack_env(env("HTTP_X_FORWARDED_PROTO" => "https:"))[:scheme]).to eq("https")
  end

  it "keeps an IPv6 literal whole and splits its port off" do
    resolved = described_class.from_rack_env(env("HTTP_HOST" => "[2001:DB8::1]:8443"))

    expect(resolved).to eq(scheme: "https", host: "[2001:db8::1]", port: 8443)
  end
end
