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
        ip_address: "203.0.113.7"
      )
    end
  end

  describe "what it hands back" do
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
  end
end
