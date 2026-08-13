# frozen_string_literal: true

require "spec_helper"

# This is the code that decides whether a caller's request is allowed to
# proceed, so everything below drives the real object and stubs only Excon --
# the actual network boundary. Authorizing a request is a single conversation
# with intake now: this service presents its own Basic credentials, the same
# ones AccessTokens would have exchanged for a Bearer token before -- minting
# one to call the party that already holds the credential bought nothing, so
# that hop, and the 401-retry that existed only to discard a stale Bearer, are
# both gone. See "the credential it presents" below.
#
# rubocop:disable Metrics/BlockLength
RSpec.describe EndPointBlank::Commands::EndpointAuthorize do
  let(:configuration) { EndPointBlank::Configuration.instance }
  let(:logger) { double("logger", info: nil, error: nil, warn: nil, debug: nil) }

  let(:authorized_body) { JSON.generate(data: [{ "source_application_environment_id" => 42 }]) }
  let(:deprecated_body) { JSON.generate(data: [], deprecation: { "deprecated_at" => "2026-01-01T00:00:00Z" }) }

  # Consumed in order; the last entry is reused so tests can assert on call
  # counts rather than on queue bookkeeping.
  let(:authorize_queue) { [http_response(201, authorized_body)] }

  let(:authorize_calls) { [] }

  def http_response(status, body)
    double("response", status: status, body: body)
  end

  def request_double(auth: "Bearer client-token", method: "GET", pattern: "/widgets(.:format)",
                     host: "api.example.test", ip: "203.0.113.7", uuid: "req-1",
                     path: "/widgets", version: "v1", env: nil)
    double(
      "request",
      headers: { "Authorization" => auth },
      request_method: method,
      route_uri_pattern: pattern,
      host: host,
      remote_ip: ip,
      uuid: uuid,
      path: path,
      params: { "version" => version },
      env: env || { "HTTP_HOST" => host }
    )
  end

  around do |example|
    original = %i[@client_id @client_secret @app_name].each_with_object({}) do |ivar, memo|
      memo[ivar] = configuration.instance_variable_get(ivar)
    end

    example.run

    original.each { |ivar, value| configuration.instance_variable_set(ivar, value) }
    EndPointBlank::Commands::AuthenticationCache.instance.clear
    # authorize no longer touches the token cache itself, but clearing it here
    # stops a token minted by some other spec from lingering: a leftover entry
    # would make "never requests an access token" pass even if a regression
    # reintroduced the Bearer exchange, since Authorization.header would find
    # a cache hit and never call the generator at all.
    EndPointBlank::AccessTokens.instance.clear
    EndPointBlank::Rack::EnvStore.clear
  end

  before do
    allow(EndPointBlank).to receive(:logger).and_return(logger)
    configuration.client_id = "cid"
    configuration.client_secret = "csecret"
    configuration.app_name = "spec-app"
    EndPointBlank::Commands::AuthenticationCache.instance.clear
    EndPointBlank::AccessTokens.instance.clear
    EndPointBlank::Rack::EnvStore.clear

    allow(Excon).to receive(:post) do |_url, options|
      authorize_calls << {
        body: JSON.parse(options[:body], symbolize_names: true),
        auth: options[:headers]["Authorization"]
      }
      queued = authorize_queue.size > 1 ? authorize_queue.shift : authorize_queue.first
      raise queued if queued.is_a?(Exception)

      queued
    end
  end

  describe "asking intake to authorize a request" do
    it "sends the caller's identity, the route, and the endpoint version" do
      described_class.authorize(request_double)

      expect(authorize_calls.size).to eq(1)
      expect(authorize_calls.first[:body]).to include(
        path: "/widgets",
        http_method: "GET",
        client_auth: "Bearer client-token",
        target_hostname: "api.example.test",
        application: "spec-app",
        endpoint_version: "1",
        source_ip: "203.0.113.7",
        uuid: "req-1"
      )
    end

    it "strips a route's optional segments so every request on a route reports the same path" do
      described_class.authorize(request_double(pattern: "/widgets/:id(.:format)"))

      expect(authorize_calls.first[:body][:path]).to eq("/widgets/:id")
    end

    it "returns the authorization service's response" do
      result = described_class.authorize(request_double)

      expect(result.status).to eq(201)
      expect(JSON.parse(result.body)).to eq("data" => [{ "source_application_environment_id" => 42 }])
    end
  end

  describe "caching an authorization" do
    it "does not ask intake again for an identical request" do
      described_class.authorize(request_double)
      described_class.authorize(request_double)

      expect(authorize_calls.size).to eq(1)
    end

    # Regression: the cache used to hold a truthy marker rather than the body,
    # so a cache hit came back with an empty body and the caller's JSON.parse
    # raised -- a cached authorization turned into a 500 instead of a fast
    # success.
    it "serves the cache hit with the original response body" do
      first = described_class.authorize(request_double)
      second = described_class.authorize(request_double)

      expect(second.status).to eq(201)
      expect(second.body).to eq(first.body)
      expect { JSON.parse(second.body) }.not_to raise_error
    end

    # The deprecation block lives in the body. If the cache dropped it, the
    # Deprecation and Sunset headers would appear only on cache misses, which
    # reads to a consumer as a flaky feature rather than a missing one.
    it "still carries the deprecation block on a cache hit" do
      authorize_queue.replace([http_response(201, deprecated_body)])

      described_class.authorize(request_double)
      cached = described_class.authorize(request_double)

      expect(JSON.parse(cached.body)["deprecation"]).to eq("deprecated_at" => "2026-01-01T00:00:00Z")
    end

    it "does not cache a refusal" do
      authorize_queue.replace([http_response(403, JSON.generate(error: "forbidden"))])

      described_class.authorize(request_double)
      described_class.authorize(request_double)

      expect(authorize_calls.size).to eq(2)
    end

    it "does not cache an unreachable authorization service" do
      allow(EndPointBlank::Commands::Http).to receive(:sleep)
      authorize_queue.replace([Excon::Error::Timeout.new("timed out")])

      described_class.authorize(request_double)
      authorize_calls.clear
      described_class.authorize(request_double)

      expect(authorize_calls).not_to be_empty
    end
  end

  describe "what counts as a different authorization" do
    def authorize_both(second)
      described_class.authorize(request_double)
      described_class.authorize(second)
      authorize_calls.size
    end

    it "asks again for a different client credential" do
      expect(authorize_both(request_double(auth: "Bearer someone-else"))).to eq(2)
    end

    it "asks again for a different route" do
      expect(authorize_both(request_double(pattern: "/gadgets(.:format)"))).to eq(2)
    end

    it "asks again for a different HTTP method" do
      expect(authorize_both(request_double(method: "DELETE"))).to eq(2)
    end

    it "asks again for a different application" do
      described_class.authorize(request_double)
      configuration.app_name = "other-app"
      described_class.authorize(request_double)

      expect(authorize_calls.size).to eq(2)
    end

    # Regression: the key omitted the endpoint version, so two callers on
    # different versions of the same route shared one entry. Whichever
    # authorized first decided for both -- a caller on a deprecated version
    # could get no warning, and one on a current version could be told it is
    # retiring.
    it "asks again for a different endpoint version of the same route" do
      expect(authorize_both(request_double(version: "v2"))).to eq(2)
    end

    it "gives each version its own answer rather than the first one to arrive" do
      authorize_queue.replace([http_response(201, deprecated_body), http_response(201, JSON.generate(data: []))])

      deprecated = described_class.authorize(request_double(version: "v1"))
      current = described_class.authorize(request_double(version: "v2"))

      expect(JSON.parse(deprecated.body)).to have_key("deprecation")
      expect(JSON.parse(current.body)).not_to have_key("deprecation")
    end
  end

  # Basic, not Bearer: this call is to intake, which already holds this
  # service's credential, so minting a token to present it back bought
  # nothing. With no Bearer there is no stale token, so there is nothing left
  # to retry either -- a 401 here means the credential itself is wrong.
  describe "the credential it presents" do
    it "authenticates with the configured Basic credentials" do
      described_class.authorize(request_double)

      expect(authorize_calls.first[:auth]).to eq("Basic #{Base64.strict_encode64("cid:csecret")}")
    end

    # The pin for the whole change: no access token is minted for this call,
    # under any circumstance -- there is no longer a code path in
    # endpoint_authorize that could produce one.
    it "never requests an access token" do
      allow(EndPointBlank::Commands::GenerateAccessToken).to receive(:token)

      described_class.authorize(request_double)

      expect(EndPointBlank::Commands::GenerateAccessToken).not_to have_received(:token)
    end

    # A Basic credential cannot have gone stale, so there is nothing for a
    # retry to accomplish -- a 401 is surfaced as-is.
    it "returns a rejection without retrying" do
      authorize_queue.replace([http_response(401, JSON.generate(error: "denied"))])

      result = described_class.authorize(request_double)

      expect(authorize_calls.size).to eq(1)
      expect(result.status).to eq(401)
    end
  end

  describe "when the authorization service cannot be reached" do
    before { allow(EndPointBlank::Commands::Http).to receive(:sleep) }

    it "returns nil rather than raising into the request" do
      authorize_queue.replace([Excon::Error::Timeout.new("timed out")])

      result = nil
      expect { result = described_class.authorize(request_double) }.not_to raise_error
      expect(result).to be_nil
    end
  end

  describe "reporting" do
    it "logs a refusal at error level so a misconfigured caller is visible in the host app's logs" do
      authorize_queue.replace([http_response(403, JSON.generate(error: "forbidden"))])

      described_class.authorize(request_double)

      expect(logger).to have_received(:error).with(/403/)
    end

    it "does not log an error for a successful authorization" do
      described_class.authorize(request_double)

      expect(logger).not_to have_received(:error)
    end
  end

  # request_double's `host:` stands in for the old ActionDispatch::Request#host
  # (which reads the last X-Forwarded-Host hop unconditionally); `env:` is
  # what BaseUrl.hostname_from_rack_env reads instead. Every example below was
  # verified, by temporarily reverting the rewire at endpoint_authorize.rb's
  # `hostname = ...` line back to `request.host`, to fail before the rewire
  # and pass after it -- `host:` is always set to a value the correct,
  # env-derived answer cannot equal, so a reversion is always caught here.
  #
  # Only "ignores X-Forwarded-Host" models the actual production risk this
  # task exists to fix: its `host:` is the value a real, proxied
  # ActionDispatch::Request#host returns today (the forwarded hop), while
  # `env:` carries the true Host header alongside it, so this example
  # reproduces the real pre-fix/post-fix behavior change described in the
  # README. The other three examples' `host:` values are not standing in for
  # any real request shape -- they are arbitrary sentinels chosen only to
  # prove `env`, not `host`, is now the source consulted; they exercise the
  # resolver's own contract (case normalization and IPv6) via this command,
  # not the forwarding divergence.
  #
  # This is purely a request-body field now -- target_hostname no longer feeds
  # the access-token cache key, because this call no longer requests a token
  # at all (see "the credential it presents" above).
  describe "the hostname it reports" do
    it "lowercases it and strips the port" do
      described_class.authorize(request_double(host: "internal.svc", env: { "HTTP_HOST" => "API.Example.TEST:3000" }))

      expect(authorize_calls.first[:body][:target_hostname]).to eq("api.example.test")
    end

    it "keeps an IPv6 literal whole and bracketed" do
      described_class.authorize(request_double(host: "internal.svc", env: { "HTTP_HOST" => "[2001:DB8::1]:8443" }))

      expect(authorize_calls.first[:body][:target_hostname]).to eq("[2001:db8::1]")
    end

    it "ignores X-Forwarded-Host" do
      described_class.authorize(request_double(
                                  host: "api.example.test",
                                  env: { "HTTP_HOST" => "internal.svc", "HTTP_X_FORWARDED_HOST" => "api.example.test" }
                                ))

      expect(authorize_calls.first[:body][:target_hostname]).to eq("internal.svc")
    end

    it "reports nil when the host is unusable" do
      described_class.authorize(request_double(
                                  host: "api.example.test",
                                  env: { "HTTP_HOST" => "api.example.test/../evil" }
                                ))

      expect(authorize_calls.first[:body][:target_hostname]).to be_nil
    end
  end
end
# rubocop:enable Metrics/BlockLength
