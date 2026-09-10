# frozen_string_literal: true

require "spec_helper"

# The guard that decides whether a caller reaches a controller at all, so
# everything below drives the real concern and the real command and stubs only
# Excon -- the actual network boundary -- exactly as `endpoint_authorize_spec`
# does for the sibling path.
#
# WHAT THESE CAN AND CANNOT PROVE AGAINST THE PRE-CHANGE CODE. Every example in
# this file fails against master, but almost all of them fail the same way: with
# `NameError: uninitialized constant EndPointBlank::Commands::EndpointAuthenticate`
# raised from the `before_action`, before any assertion is reached. That is the
# bug (sc-306), and it is why no amount of this file distinguishes "master gets
# the status wrong" from "master never gets that far". The status behaviour
# (sc-307) could not be regression-tested here at all, because on master there is
# no reachable refusal to test; it is proved instead against a build with only
# the missing constant repaired -- see the end-to-end table in the pull request.
#
# rubocop:disable Metrics/BlockLength
RSpec.describe EndPointBlank::Rails::Authenticated do
  let(:configuration) { EndPointBlank::Configuration.instance }
  let(:logger) { double("logger", info: nil, error: nil, warn: nil, debug: nil) }

  let(:controller_class) { guarded_controller_class(described_class) }
  let(:controller) { controller_class.new(guarded_request) }

  # Consumed in order; the last entry is reused, so a spec can assert on call
  # counts rather than on queue bookkeeping.
  let(:intake_queue) { [intake_answer(201, '{"data":[]}')] }
  let(:intake_calls) { [] }

  around do |example|
    original = %i[@client_id @client_secret @app_name].each_with_object({}) do |ivar, memo|
      memo[ivar] = configuration.instance_variable_get(ivar)
    end

    example.run

    original.each { |ivar, value| configuration.instance_variable_set(ivar, value) }
    EndPointBlank::Commands::AuthenticationCache.instance.clear
    EndPointBlank::AccessTokens.instance.clear
  end

  before do
    allow(EndPointBlank).to receive(:logger).and_return(logger)
    configuration.client_id = "cid"
    configuration.client_secret = "csecret"
    configuration.app_name = "spec-app"
    EndPointBlank::Commands::AuthenticationCache.instance.clear
    EndPointBlank::AccessTokens.instance.clear

    # The retry sleep, not the retry itself: an unreachable intake still makes
    # all three attempts, it just does not spend 0.4s of the suite doing it.
    allow(EndPointBlank::Commands::Http).to receive(:sleep)

    allow(Excon).to receive(:post) do |_url, options|
      intake_calls << {
        body: JSON.parse(options[:body], symbolize_names: true),
        auth: options[:headers]["Authorization"]
      }
      queued = intake_queue.size > 1 ? intake_queue.shift : intake_queue.first
      raise queued if queued.is_a?(Exception)

      queued
    end
  end

  describe "installing itself" do
    # GUARD, not a regression test: this is one of only three examples in this
    # file that pass against master. Installing the `before_action` always
    # worked -- that is exactly why the failure was on every request rather than
    # at boot, and why nothing caught it.
    it "runs on every action of the controller that includes it" do
      expect(controller_class.before_actions).to eq([:authenticate!])
    end
  end

  describe "asking intake about the request" do
    # The sc-306 regression test. On master this raises
    # `NameError: uninitialized constant EndPointBlank::Commands::EndpointAuthenticate`,
    # because the concern named a command this gem has never contained.
    it "reaches the network instead of raising NameError on a missing command" do
      expect { controller.authenticate! }.not_to raise_error

      expect(intake_calls.size).to eq(1)
    end

    it "sends the caller's identity, the route and the endpoint version" do
      controller.authenticate!

      expect(intake_calls.first[:body]).to include(
        path: "/widgets",
        http_method: "GET",
        client_auth: "Bearer client-token",
        application: "spec-app",
        endpoint_version: "1",
        ip_address: "203.0.113.7"
      )
    end

    it "strips a route's optional segments so every request on a route reports the same path" do
      controller_class.new(guarded_request(pattern: "/widgets/:id(.:format)")).authenticate!

      expect(intake_calls.first[:body][:path]).to eq("/widgets/:id")
    end

    it "presents this service's own Basic credentials exactly once" do
      # Regression for the second missing constant: the command built its header
      # from `AuthorizationGenerate.generate`, which this gem has never defined
      # either, so repairing only the concern's constant would have moved the
      # NameError one frame deeper. `Authorization.header` already returns a
      # complete "Basic <base64>" string -- re-wrapping it would send
      # "Basic Basic ..." and intake would refuse every request.
      controller.authenticate!

      expect(intake_calls.first[:auth]).to eq("Basic #{Base64.encode64('cid:csecret').gsub("\n", '')}")
    end

    it "does not ask intake a second time for the same request" do
      # Unlike `authorize!`, this path deliberately does not cache -- matching
      # every other SDK's authenticate command. Pinned so that acquiring a cache
      # is a decision someone makes, not something that arrives by accident.
      controller.authenticate!
      controller.authenticate!

      expect(intake_calls.size).to eq(2)
    end
  end

  describe "when intake says 201" do
    it "lets the request through" do
      expect { controller.authenticate! }.not_to raise_error
    end
  end

  # Runs the guard against one intake answer and hands back whatever it raised,
  # or nil if it let the request through. Anything other than an
  # UnauthorizedError comes back as itself rather than being swallowed, so a
  # NameError or a NoMethodError shows up as the wrong class instead of as a
  # missing status.
  def refusal_for(answer)
    intake_queue.replace([answer])
    controller.authenticate!
    nil
  rescue StandardError => e
    e
  end

  describe "the status the refusal carries" do
    it "keeps a denied grant's 403 rather than collapsing it to 401" do
      # 401 and 403 are different remedies: re-check the credential, versus ask
      # for a grant covering this endpoint. `raise UnauthorizedError, "message"`
      # -- the form this concern used -- can only ever produce the class's 401
      # default, so both denials arrived at the caller identically.
      expect(refusal_for(intake_answer(403, '{"error":"access_denied"}')).status).to eq(403)
    end

    it "keeps a rejected credential's 401" do
      expect(refusal_for(intake_answer(401, '{"error":"invalid_client"}')).status).to eq(401)
    end

    it "surfaces a failure inside intake as its own 5xx" do
      expect(refusal_for(intake_answer(500, "boom")).status).to eq(500)
    end

    it "keeps the status of an error body that is not JSON" do
      refusal = refusal_for(intake_answer(502, "Bad Gateway"))

      expect(refusal.status).to eq(502)
      expect(refusal.message).to eq("Authentication failed: Bad Gateway")
    end

    it "refuses an unexpected success status as that status" do
      expect(refusal_for(intake_answer(200, "")).status).to eq(200)
    end

    it "gives the reason intake gave" do
      expect(refusal_for(intake_answer(403, '{"error":"access_denied"}')).message)
        .to eq("Authentication failed: access_denied")
    end
  end

  describe "when intake does not answer at all" do
    let(:unreachable) { Excon::Error.new("connection refused") }

    it "refuses the request rather than letting it through" do
      # Fails closed. An outage must never become an open door.
      expect(refusal_for(unreachable)).to be_a(EndPointBlank::UnauthorizedError)
    end

    it "says 503, because no credential was ever judged" do
      # Not 401: nothing refused this caller and no credential was looked at,
      # so blaming the credential sends an integrator to re-issue one that is
      # fine. `authorize!` has always answered 503 here, as do all four of the
      # other SDKs.
      expect(refusal_for(unreachable).status).to eq(503)
    end

    it "reaches the branch written for nil instead of dying on nil first" do
      # The dead guard. `result_json = JSON.parse(result.body)` ran on the line
      # ABOVE `if !result || ...`, so a nil result could never reach the branch
      # written for it -- it died with NoMethodError on nil.body. Repairing only
      # the missing constant would have uncovered exactly this, which is why
      # both were fixed in one pass. Asserted as the class of what comes back,
      # because `not_to raise_error(NoMethodError)` would pass for a NameError
      # too.
      expect(refusal_for(unreachable).class).to eq(EndPointBlank::UnauthorizedError)
    end
  end
end
# rubocop:enable Metrics/BlockLength
