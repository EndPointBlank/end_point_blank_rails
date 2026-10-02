# frozen_string_literal: true

require "spec_helper"
require "securerandom"

# Runs the management client against a real app_portal (a local one, or the
# test apps), only when both are set:
#
#   EPB_MGMT_BASE_URL=http://localhost:4000 EPB_MGMT_KEY=epb_mk_... bundle exec rspec \
#     spec/end_point_blank/management/integration_spec.rb
#
# The key must be a write key. Everything the spec creates is named
# "sdk-it-<random>" and removed again at the end, also when a step fails.
# Domain refusals that depend on the organization's state (nothing deployed
# yet, a plan limit) are asserted by their code rather than failing the run.
RSpec.describe "EndPointBlank::Management::Client against app_portal" do
  before do
    skip "set EPB_MGMT_BASE_URL and EPB_MGMT_KEY to run" unless ENV["EPB_MGMT_BASE_URL"] && ENV["EPB_MGMT_KEY"]
  end

  let(:mgmt) do
    EndPointBlank::Management::Client.new(api_key: ENV.fetch("EPB_MGMT_KEY"), base_url: ENV.fetch("EPB_MGMT_BASE_URL"))
  end
  let(:tag) { "sdk-it-#{SecureRandom.hex(4)}" }
  let(:cleanup) { [] }

  after do
    cleanup.reverse_each do |step|
      step.call
    rescue EndPointBlank::Management::Error => e
      warn "[integration cleanup] #{e.code}: #{e.message}"
    end
  end

  # Runs the block; a refusal with one of +codes+ is the expected outcome for
  # this organization's state and answers nil instead of failing.
  def tolerating(*codes)
    yield
  rescue EndPointBlank::Management::Error => e
    raise unless codes.include?(e.code)

    nil
  end

  def environment_and_application(scope, name)
    environment = scope.environments.create(name: "#{name}-env", domain: "#{name}.example.test")
    cleanup << -> { scope.environments.delete(environment["id"]) }
    application = scope.applications.create(
      name: "#{name}-app", environment_base_urls: { environment["id"] => "https://#{name}.example.test" }
    )
    cleanup << -> { scope.applications.delete(application["id"]) }
    [environment, application]
  end

  def credential_lifecycle(scope, application_environment_id)
    credential = scope.credentials.create(application_environment_id: application_environment_id)
    revoke = -> { tolerating("not_found") { scope.credentials.revoke(credential["id"]) } }
    cleanup << revoke
    expect(credential["client_secret"]).to be_a(String)

    rotated = scope.credentials.rotate(credential["id"])
    expect(rotated["id"]).to eq(credential["id"])
    expect(rotated["client_secret"]).not_to eq(credential["client_secret"])
    expect(scope.credentials.get(credential["id"])).not_to have_key("client_secret")

    expect(scope.credentials.revoke(credential["id"])).to include("id" => credential["id"], "deleted" => true)
    cleanup.delete(revoke)
  end

  it "manages the organization's packages, clients, applications and credentials" do
    organization = mgmt.organization
    expect(organization["id"]).to be_a(String)
    expect(organization.dig("key", "scope")).to eq("write")

    environment, application = environment_and_application(mgmt, tag)
    second_environment = mgmt.environments.create(name: "#{tag}-env2", domain: "#{tag}-2.example.test")
    cleanup << -> { mgmt.environments.delete(second_environment["id"]) }
    application_environment = mgmt.applications.add_environment(
      application["id"], environment_id: second_environment["id"], base_url: "https://#{tag}-2.example.test"
    )
    cleanup << -> { mgmt.applications.remove_environment(application["id"], application_environment["id"]) }
    expect(mgmt.applications.each_environment(application["id"]).map { |row| row["id"] })
      .to include(application_environment["id"])

    package = mgmt.api_packages.create(name: "#{tag}-package")
    cleanup << -> { mgmt.api_packages.delete(package["id"]) }
    expect(mgmt.api_packages.each.map { |row| row["id"] }).to include(package["id"])

    # Add the first deployed endpoint, if the organization has one.
    endpoint = mgmt.endpoints.list(limit: 1).first
    endpoint_environment = endpoint && mgmt.applications.list_environments(endpoint["application_id"]).first
    package_environment_id = endpoint_environment ? endpoint_environment["environment_id"] : environment["id"]
    if endpoint_environment
      added = mgmt.api_packages.add_endpoint(package["id"], application_id: endpoint["application_id"],
                                                            endpoint_id: endpoint["id"],
                                                            environment_id: package_environment_id)
      expect(added["data"]["endpoint_id"]).to eq(endpoint["id"])
      expect(added["warnings"]).to be_an(Array)
      cleanup << -> { mgmt.api_packages.remove_endpoint(package["id"], added["data"]["id"]) }
    end

    invited = tolerating("plan_limit") do
      mgmt.clients.invite(name: "#{tag}-client",
                          contacts: [{ email: "#{tag}@example.test", first_name: "Sdk", last_name: "Test" }])
    end
    if invited
      cleanup << -> { mgmt.clients.delete(invited["id"]) }
      expect(invited["status"]).to eq("pending")

      assignment = tolerating("nothing_published_in_environment") do
        mgmt.package_assignments.assign(invited["id"], api_package_id: package["id"],
                                                       environment_id: package_environment_id)
      end
      if assignment
        expect(assignment["status"]).to eq("pending")
        expect(mgmt.package_assignments.list(invited["id"]).map { |row| row["id"] }).to include(assignment["id"])
        mgmt.package_assignments.delete(invited["id"], assignment["id"])
      end
    end

    credential_lifecycle(mgmt, application_environment["id"])

    missing = tolerating("not_found") { mgmt.api_packages.get(SecureRandom.uuid) }
    expect(missing).to be_nil
  end

  it "sets up a managed client for a customer, then removes it" do
    managed = tolerating("plan_limit") { mgmt.clients.create_managed(name: "#{tag}-managed") }
    skip "the plan's client limit is reached" unless managed
    cleanup << -> { mgmt.clients.delete(managed["id"]) }
    expect(managed["managed"]).to be(true)

    customer = mgmt.for_managed_client(managed["id"])
    environment, application = environment_and_application(customer, "#{tag}-m")
    application_environment = customer.applications.list_environments(application["id"]).find do |row|
      row["environment_id"] == environment["id"]
    end

    credential_lifecycle(customer, application_environment["id"])
  end
end
