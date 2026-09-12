# frozen_string_literal: true

require "spec_helper"

# The command behind `Rails::Authenticated`, and the one the JS, Java and Python
# SDKs each document their own authenticate command as a port of. It had no spec
# at all before this, which is how it kept a reference to
# `AuthorizationGenerate` -- a constant this gem has never defined -- for as long
# as it did: its only caller named a constant that did not exist either, so
# nothing ever ran it.
#
# Everything below drives the real command and stubs only Excon, the actual
# network boundary.
RSpec.describe EndPointBlank::Commands::BasicAuthenticate do
  let(:configuration) { EndPointBlank::Configuration.instance }
  let(:logger) { double("logger", info: nil, error: nil, warn: nil, debug: nil) }

  let(:answer) { intake_answer(201, '{"data":[]}') }
  let(:calls) { [] }

  around do |example|
    original = %i[@client_id @client_secret @app_name].each_with_object({}) do |ivar, memo|
      memo[ivar] = configuration.instance_variable_get(ivar)
    end

    example.run

    original.each { |ivar, value| configuration.instance_variable_set(ivar, value) }
    EndPointBlank::AccessTokens.instance.clear
  end

  before do
    allow(EndPointBlank).to receive(:logger).and_return(logger)
    configuration.client_id = "cid"
    configuration.client_secret = "csecret"
    configuration.app_name = "spec-app"
    EndPointBlank::AccessTokens.instance.clear

    allow(EndPointBlank::Commands::Http).to receive(:sleep)
    allow(Excon).to receive(:post) do |url, options|
      calls << { url: url, auth: options[:headers]["Authorization"],
                 body: JSON.parse(options[:body], symbolize_names: true) }
      raise answer if answer.is_a?(Exception)

      answer
    end
  end

  describe "the credential it presents" do
    it "is this service's own Basic credentials, built once" do
      # It read `"Basic #{AuthorizationGenerate.generate}"`, naming a constant
      # that does not exist -- so this command raised NameError before it could
      # reach the network. `Authorization.header` called with no argument
      # already returns the complete "Basic <base64>" string; wrapping it in a
      # second "Basic " would send "Basic Basic ..." and intake would refuse
      # every request that used this path.
      described_class.authenticate(guarded_request)

      expect(calls.first[:auth]).to eq("Basic #{Base64.encode64('cid:csecret').gsub("\n", '')}")
    end

    it "is Basic, not Bearer -- intake already holds this service's credential" do
      described_class.authenticate(guarded_request)

      expect(calls.first[:auth]).to start_with("Basic ")
    end
  end

  describe "the request it sends" do
    it "goes to the authorize endpoint" do
      described_class.authenticate(guarded_request)

      expect(calls.first[:url]).to eq(configuration.authorize_url)
    end

    it "carries the route, the method, the caller's credential and the version" do
      described_class.authenticate(guarded_request)

      expect(calls.first[:body]).to include(
        path: "/widgets",
        http_method: "GET",
        client_auth: "Bearer client-token",
        application: "spec-app",
        endpoint_version: "1",
        source_ip: "203.0.113.7"
      )
    end

    # intake reads `source_ip`. This command sent `ip_address`, and intake
    # ignores keys it does not cast, so nothing failed and nothing said
    # anything -- `source_ip_address` was simply NULL on every authenticate row
    # from a Rails application. The key is asserted as a literal against the
    # body that actually went over the wire; a double that accepts any body
    # would prove nothing, which is how a key bug survives.
    it "names the caller's IP the way intake reads it" do
      described_class.authenticate(guarded_request)

      expect(calls.first[:body]).to include(source_ip: "203.0.113.7")
      expect(calls.first[:body]).not_to have_key(:ip_address)
    end
  end

  describe "what it hands back" do
    it "records the granted source environment for the current request" do
      EndPointBlank::Rack::EnvStore.set({})
      answer_body = JSON.generate(
        "data" => [{ "source_application_environment_id" => "source-env-123" }]
      )
      allow(Excon).to receive(:post) do |url, options|
        calls << { url: url, auth: options[:headers]["Authorization"],
                   body: JSON.parse(options[:body], symbolize_names: true) }
        intake_answer(201, answer_body)
      end

      described_class.authenticate(guarded_request)

      expect(EndPointBlank::Rack::EnvStore.source_application_environment_id).to eq("source-env-123")
    ensure
      EndPointBlank::Rack::EnvStore.clear
    end

    it "is intake's response" do
      expect(described_class.authenticate(guarded_request).status).to eq(201)
    end

    context "when intake refuses the caller" do
      let(:answer) { intake_answer(403, '{"error":"access_denied"}') }

      it "is intake's refusal, status intact, rather than an exception" do
        # The caller needs the status to tell a denied grant from a rejected
        # credential, so a refusal is a return value here, not a raise.
        expect(described_class.authenticate(guarded_request).status).to eq(403)
      end
    end

    context "when intake cannot be reached" do
      let(:answer) { Excon::Error.new("connection refused") }

      it "is nil, which the caller reads as 503" do
        expect(described_class.authenticate(guarded_request)).to be_nil
      end
    end

    # `JSON.parse` accepts any RFC 7159 document, not just objects: `null`,
    # `[]`, `5` and `"x"` all parse without raising `JSON::ParserError`. Code
    # that only rescues that one error class and then calls `.dig` on
    # whatever came back raises `TypeError`/`NoMethodError` instead, and
    # nothing catches those -- they escape `authenticate`, escape
    # `before_action :authenticate!`, and the host application answers 500 to
    # a caller intake just finished authenticating. A metadata-recording
    # change must never flip the flow's pass/fail outcome, so a 201 has to
    # stay a 201 no matter what shape its body turns out to be.
    context "when intake answers 201 with a body that is valid JSON but not an object" do
      let(:answer) { intake_answer(201, "[]") }

      it "is still intake's response, status intact, rather than an exception" do
        expect(described_class.authenticate(guarded_request).status).to eq(201)
      end
    end
  end
end
