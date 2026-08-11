# frozen_string_literal: true

require "spec_helper"

# rubocop:disable Metrics/BlockLength
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

  it "omits the port and the scheme when only a forwarded host and port are present" do
    # FINDING A: with no X-Forwarded-Proto, the scheme cannot be resolved, so
    # a port cannot be classified against a default either -- reporting 443
    # here would be a guess, not an observation, so it is withheld along with
    # the scheme rather than reported unclassified.
    resolved = described_class.from_rack_env(env(
                                               "HTTP_X_FORWARDED_HOST" => "api.example.com",
                                               "HTTP_X_FORWARDED_PORT" => "443"
                                             ))

    expect(resolved).to eq(host: "api.example.com")
  end

  it "keeps the connection scheme and the authority port when X-Forwarded-Port is malformed" do
    # FINDING B: "not-a-port" must not count as proxy evidence -- an
    # unauthenticated caller could otherwise blank a perfectly good scheme and
    # port just by sending garbage. The connection scheme and the port
    # embedded in Host stay evidence, exactly as if the header were absent.
    resolved = described_class.from_rack_env(env(
                                               "rack.url_scheme" => "https",
                                               "SERVER_PORT" => "8080",
                                               "HTTP_HOST" => "api.example.com:9000",
                                               "HTTP_X_FORWARDED_PORT" => "not-a-port"
                                             ))

    expect(resolved).to eq(scheme: "https", host: "api.example.com", port: 9000)
  end

  it "keeps the connection scheme when X-Forwarded-Proto is malformed" do
    # FINDING B: the junk proto must not erase the scheme just because a
    # valid X-Forwarded-Host happens to be present too -- Host alone is not
    # evidence that the connection's scheme belongs to a proxy.
    resolved = described_class.from_rack_env(env(
                                               "HTTP_X_FORWARDED_PROTO" => "not a scheme",
                                               "HTTP_X_FORWARDED_HOST" => "api.example.com",
                                               "SERVER_PORT" => "443"
                                             ))

    expect(resolved).to eq(scheme: "https", host: "api.example.com")
  end

  it "drops a host longer than 253 bytes rather than reporting or truncating it" do
    # DNS caps a hostname at 253 characters and the receiving column is
    # varchar(255); no web-server adapter validates X-Forwarded-Host's length,
    # so this is the only thing standing between a caller and an oversized
    # value. Dropped outright, not truncated -- a truncated hostname is a
    # plausible-looking WRONG one. An oversized X-Forwarded-Host falls back to
    # the direct Host header exactly like any other malformed one, so it is
    # set oversized too: the point here is the cap itself, not the fallback
    # (covered by "falls back to the direct Host header" below). scheme and
    # port still resolve from their own, independent (connection) sources,
    # unaffected by the rejection.
    resolved = described_class.from_rack_env(env(
                                               "HTTP_X_FORWARDED_HOST" => "a" * 300,
                                               "HTTP_HOST" => "a" * 300
                                             ))

    expect(resolved).not_to have_key(:host)
    expect(resolved).to eq(scheme: "https", port: 8443)
  end

  it "falls back to the direct Host header when X-Forwarded-Host is too long to use" do
    # Same treatment Finding B gives a malformed proto or port: ignored
    # entirely, not left unresolved.
    resolved = described_class.from_rack_env(env("HTTP_X_FORWARDED_HOST" => "a" * 300))

    expect(resolved[:host]).to eq("api.example.com")
  end

  it "keeps a host at exactly 253 bytes and drops one at 254" do
    expect(described_class.from_rack_env(env("HTTP_HOST" => "a" * 253))[:host]).to eq("a" * 253)
    expect(described_class.from_rack_env(env("HTTP_HOST" => "a" * 254))).not_to have_key(:host)
  end

  describe ".hostname_from_rack_env" do
    it "lowercases the host and strips the port" do
      expect(described_class.hostname_from_rack_env(env)).to eq("api.example.com")
    end

    it "keeps an IPv6 literal whole and bracketed" do
      resolved = described_class.hostname_from_rack_env(env("HTTP_HOST" => "[2001:DB8::1]:8443"))

      expect(resolved).to eq("[2001:db8::1]")
    end

    it "ignores X-Forwarded-Host even though from_rack_env honors it" do
      # target_hostname is the portal's application-environment lookup key. A
      # value matching no registered row is a hard 422, not a cache miss.
      proxied = env("HTTP_HOST" => "internal.svc", "HTTP_X_FORWARDED_HOST" => "api.example.com")

      expect(described_class.hostname_from_rack_env(proxied)).to eq("internal.svc")
      expect(described_class.from_rack_env(proxied)[:host]).to eq("api.example.com")
    end

    it "falls back to SERVER_NAME when there is no Host header" do
      resolved = described_class.hostname_from_rack_env(env("HTTP_HOST" => nil))

      expect(resolved).to eq("api.example.com")
    end

    it "is nil for a host that is not shaped like a hostname" do
      resolved = described_class.hostname_from_rack_env(env("HTTP_HOST" => "api.example.com/../evil"))

      expect(resolved).to be_nil
    end

    it "is nil for a host longer than DNS allows" do
      resolved = described_class.hostname_from_rack_env(
        env("HTTP_HOST" => "#{"a" * 250}.example.com", "SERVER_NAME" => nil)
      )

      expect(resolved).to be_nil
    end

    it "is nil when handed something that is not a Rack env" do
      expect(described_class.hostname_from_rack_env(nil)).to be_nil
    end
  end
end
# rubocop:enable Metrics/BlockLength
