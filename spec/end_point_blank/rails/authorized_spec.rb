# frozen_string_literal: true

require "spec_helper"

# What `authorize!` leaves in the request store for the writers once intake
# grants a request. Drives the real concern and the real command, stubbing
# only Excon, as `authenticated_spec` does for the sibling guard.
RSpec.describe EndPointBlank::Rails::Authorized do
  let(:configuration) { EndPointBlank::Configuration.instance }
  let(:logger) { double("logger", info: nil, error: nil, warn: nil, debug: nil) }
  let(:request) { guarded_request }

  let(:granting) do
    JSON.generate(
      data: [{
        "id" => "gen-1",
        "source_application_environment_id" => "app-env-1",
        "target_application_environment_id" => "tgt-env",
        "source_organization_id" => "org-1",
        "inserted_at" => "2026-01-01T00:00:00Z"
      }]
    )
  end

  around do |example|
    original = %i[@client_id @client_secret @app_name].each_with_object({}) do |ivar, memo|
      memo[ivar] = configuration.instance_variable_get(ivar)
    end

    example.run

    original.each { |ivar, value| configuration.instance_variable_set(ivar, value) }
    EndPointBlank::Commands::AuthenticationCache.instance.clear
    EndPointBlank::Rack::EnvStore.clear
  end

  before do
    allow(EndPointBlank).to receive(:logger).and_return(logger)
    configuration.client_id = "cid"
    configuration.client_secret = "csecret"
    configuration.app_name = "spec-app"
    EndPointBlank::Commands::AuthenticationCache.instance.clear
    EndPointBlank::Rack::EnvStore.set(request.env)

    allow(Excon).to receive(:post).and_return(intake_answer(201, granting))
  end

  def authorize!
    guarded_controller_class(described_class).new(request).authorize!
  end

  it "records the source environment the grant names" do
    authorize!

    expect(EndPointBlank::Rack::EnvStore.source_application_environment_id).to eq("app-env-1")
  end

  it "records the calling organization beside it (sc-1571)" do
    authorize!

    expect(EndPointBlank::Rack::EnvStore.source_organization_id).to eq("org-1")
  end
end
