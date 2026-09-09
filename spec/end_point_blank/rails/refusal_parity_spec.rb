# frozen_string_literal: true

require "spec_helper"

# The two Rails guards make the same decision about the same answer from intake,
# and the only thing that should differ is the word in the message.
#
# They drifted: `authorize!` carried intake's status and `authenticate!` used
# `raise UnauthorizedError, "message"`, a form that structurally cannot carry
# one, so the same denial gave a caller two different answers depending on which
# concern the controller included. That divergence was invisible in a pass/fail
# count -- both guards refused the request either way, and only the status the
# caller was finally served differed. This pins them together so the next fix
# cannot land on one of them alone.
#
# The `authorize!` half of every row below is a GUARD: it passes against master,
# because that path was already right. The `authenticate!` half cannot fail
# against master for the reason this file is about -- it fails earlier, with
# NameError, which is sc-306.
#
# rubocop:disable Metrics/BlockLength
RSpec.describe "the two Rails guards refuse identically" do
  let(:configuration) { EndPointBlank::Configuration.instance }
  let(:logger) { double("logger", info: nil, error: nil, warn: nil, debug: nil) }

  let(:intake_queue) { [] }

  around do |example|
    original = %i[@client_id @client_secret @app_name].each_with_object({}) do |ivar, memo|
      memo[ivar] = configuration.instance_variable_get(ivar)
    end

    example.run

    original.each { |ivar, value| configuration.instance_variable_set(ivar, value) }
    EndPointBlank::Commands::AuthenticationCache.instance.clear
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

    allow(EndPointBlank::Commands::Http).to receive(:sleep)
    allow(Excon).to receive(:post) do |_url, _options|
      queued = intake_queue.first
      raise queued if queued.is_a?(Exception)

      queued
    end
  end

  # Runs one guard against whatever is queued and hands back what it raised.
  def refusal_from(concern, guard)
    guarded_controller_class(concern).new(guarded_request).public_send(guard)
    nil
  rescue StandardError => e
    e
  end

  def both_refusals
    [
      refusal_from(EndPointBlank::Rails::Authenticated, :authenticate!),
      refusal_from(EndPointBlank::Rails::Authorized, :authorize!)
    ]
  end

  # name, [status, body] or :unreachable, expected status
  [
    ["a denied grant", [403, '{"error":"access_denied"}'], 403],
    ["a rejected credential", [401, '{"error":"invalid_client"}'], 401],
    ["a failure inside intake", [500, "boom"], 500],
    ["a non-JSON error body", [502, "Bad Gateway"], 502],
    ["no answer at all", :unreachable, 503]
  ].each do |name, answer, expected|
    context "when intake gives #{name}" do
      before do
        intake_queue.replace(
          [answer == :unreachable ? Excon::Error.new("connection refused") : intake_answer(*answer)]
        )
      end

      it "both guards refuse with #{expected}" do
        from_authenticate, from_authorize = both_refusals

        expect(from_authenticate).to be_a(EndPointBlank::UnauthorizedError)
        expect(from_authorize).to be_a(EndPointBlank::UnauthorizedError)
        expect(from_authenticate.status).to eq(expected)
        expect(from_authorize.status).to eq(from_authenticate.status)
      end
    end
  end

  it "gives the same reason under each guard's own name" do
    intake_queue.replace([intake_answer(403, '{"error":"access_denied"}')])

    from_authenticate, from_authorize = both_refusals

    expect(from_authenticate.message).to eq("Authentication failed: access_denied")
    expect(from_authorize.message).to eq("Authorization failed: access_denied")
  end

  it "names the unreachable service under each guard's own name" do
    intake_queue.replace([Excon::Error.new("connection refused")])

    from_authenticate, from_authorize = both_refusals

    expect(from_authenticate.message).to eq("Authentication service unavailable")
    expect(from_authorize.message).to eq("Authorization service unavailable")
  end
end
# rubocop:enable Metrics/BlockLength
