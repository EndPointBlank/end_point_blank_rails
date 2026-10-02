# frozen_string_literal: true

require "spec_helper"

# Every management API call the client makes: its method, path, query and
# body, against app_portal's routes (lib/app_portal_web/router.ex, the
# /api/v1 scopes) and each controller's open_api/0.
RSpec.describe EndPointBlank::Management::Client, :management_api do
  let(:client) { management_client }
  let(:pkg) { "11111111-1111-4111-8111-111111111111" }
  let(:cid) { "22222222-2222-4222-8222-222222222222" }
  let(:app) { "33333333-3333-4333-8333-333333333333" }
  let(:env) { "44444444-4444-4444-8444-444444444444" }
  let(:other) { "55555555-5555-4555-8555-555555555555" }

  def self.call(description, method, path, query: {}, body: nil, &block)
    it "#{description} sends #{method} #{path}" do
      stub_management_api(status: 200, body: { data: { "id" => "x" }, next_cursor: nil })

      instance_exec(client, &block)

      request = management_requests.last
      expect(management_requests.size).to eq(1)
      expect(request.http_method).to eq(method)
      expect(request.path).to eq(instance_exec(&path))
      expect(request.query).to eq(query)
      expect(request.body).to eq(body.respond_to?(:call) ? instance_exec(&body) : body)
      if method == "POST"
        expect(request.header("Idempotency-Key")).to match(/\A\h{8}-\h{4}-4\h{3}-[89ab]\h{3}-\h{12}\z/)
      else
        expect(request.header("Idempotency-Key")).to be_nil
      end
    end
  end

  describe "organization" do
    call("organization", "GET", -> { "/api/v1/organization" }, &:organization)
  end

  describe "api_packages" do
    call("list", "GET", -> { "/api/v1/api_packages" }, query: { "limit" => "10", "after" => "cur" }) do |c|
      c.api_packages.list(limit: 10, after: "cur")
    end
    call("get", "GET", -> { "/api/v1/api_packages/#{pkg}" }) { |c| c.api_packages.get(pkg) }
    call("create", "POST", -> { "/api/v1/api_packages" }, body: { "name" => "Gold" }) do |c|
      c.api_packages.create(name: "Gold")
    end
    call("update", "PATCH", -> { "/api/v1/api_packages/#{pkg}" }, body: { "name" => "Platinum" }) do |c|
      c.api_packages.update(pkg, name: "Platinum")
    end
    call("delete", "DELETE", -> { "/api/v1/api_packages/#{pkg}" }) { |c| c.api_packages.delete(pkg) }
    call("list_endpoints", "GET", -> { "/api/v1/api_packages/#{pkg}/endpoints" }, query: { "limit" => "5" }) do |c|
      c.api_packages.list_endpoints(pkg, limit: 5)
    end
    call("add_endpoint (whole application)", "POST", -> { "/api/v1/api_packages/#{pkg}/endpoints" },
         body: -> { { "application_id" => app, "environment_id" => env } }) do |c|
      c.api_packages.add_endpoint(pkg, application_id: app, environment_id: env)
    end
    call("add_endpoint (one endpoint)", "POST", -> { "/api/v1/api_packages/#{pkg}/endpoints" },
         body: -> { { "application_id" => app, "endpoint_id" => other, "environment_id" => env } }) do |c|
      c.api_packages.add_endpoint(pkg, application_id: app, endpoint_id: other, environment_id: env)
    end
    call("remove_endpoint", "DELETE", -> { "/api/v1/api_packages/#{pkg}/endpoints/#{other}" }) do |c|
      c.api_packages.remove_endpoint(pkg, other)
    end
  end

  describe "endpoints" do
    call("list with filters", "GET", -> { "/api/v1/endpoints" },
         query: { "application_id" => "33333333-3333-4333-8333-333333333333", "version" => "1.0.0" }) do |c|
      c.endpoints.list(application_id: app, version: "1.0.0")
    end
    call("list", "GET", -> { "/api/v1/endpoints" }) { |c| c.endpoints.list }
  end

  describe "clients" do
    call("list", "GET", -> { "/api/v1/clients" }) { |c| c.clients.list }
    call("get", "GET", -> { "/api/v1/clients/#{cid}" }) { |c| c.clients.get(cid) }
    call("invite", "POST", -> { "/api/v1/clients" },
         body: lambda {
           {
             "name" => "Acme",
             "contacts" => [{ "email" => "a@acme.test", "first_name" => "A", "last_name" => "B" }],
             "packages" => [{ "api_package_id" => pkg, "environment_id" => env }],
             "grants" => [{ "target_application_id" => app, "environment_id" => env }]
           }
         }) do |c|
      c.clients.invite(name: "Acme",
                       contacts: [{ email: "a@acme.test", first_name: "A", last_name: "B" }],
                       packages: [{ api_package_id: pkg, environment_id: env }],
                       grants: [{ target_application_id: app, environment_id: env }])
    end
    call("create_managed", "POST", -> { "/api/v1/clients" },
         body: { "name" => "Run for Acme", "managed" => true }) do |c|
      c.clients.create_managed(name: "Run for Acme")
    end
    call("create with managed: false", "POST", -> { "/api/v1/clients" },
         body: { "name" => "Acme", "managed" => false }) do |c|
      c.clients.create(name: "Acme", managed: false)
    end
    call("delete", "DELETE", -> { "/api/v1/clients/#{cid}" }) { |c| c.clients.delete(cid) }
    call("claim_invite", "POST", -> { "/api/v1/clients/#{cid}/claim_invites" },
         body: { "email" => "owner@acme.test" }) do |c|
      c.clients.claim_invite(cid, email: "owner@acme.test")
    end
  end

  describe "package_assignments" do
    call("list", "GET", -> { "/api/v1/clients/#{cid}/packages" }) { |c| c.package_assignments.list(cid) }
    call("assign", "POST", -> { "/api/v1/clients/#{cid}/packages" },
         body: -> { { "api_package_id" => pkg, "environment_id" => env } }) do |c|
      c.package_assignments.assign(cid, api_package_id: pkg, environment_id: env)
    end
    call("update", "PATCH", -> { "/api/v1/clients/#{cid}/packages/#{other}" },
         body: -> { { "environment_id" => env } }) do |c|
      c.package_assignments.update(cid, other, environment_id: env)
    end
    call("delete", "DELETE", -> { "/api/v1/clients/#{cid}/packages/#{other}" }) do |c|
      c.package_assignments.delete(cid, other)
    end
  end

  describe "grants" do
    call("list", "GET", -> { "/api/v1/clients/#{cid}/grants" }) { |c| c.grants.list(cid) }
    call("create", "POST", -> { "/api/v1/clients/#{cid}/grants" },
         body: -> { { "target_application_id" => app, "target_endpoint_id" => other, "environment_id" => env } }) do |c|
      c.grants.create(cid, target_application_id: app, target_endpoint_id: other, environment_id: env)
    end
    call("delete", "DELETE", -> { "/api/v1/clients/#{cid}/grants/#{other}" }) { |c| c.grants.delete(cid, other) }
  end

  describe "applications" do
    call("list", "GET", -> { "/api/v1/applications" }) { |c| c.applications.list }
    call("get", "GET", -> { "/api/v1/applications/#{app}" }) { |c| c.applications.get(app) }
    call("create", "POST", -> { "/api/v1/applications" },
         body: lambda {
           { "name" => "Orders", "public" => false, "environment_base_urls" => { env => "https://orders.test" } }
         }) do |c|
      c.applications.create(name: "Orders", public: false, environment_base_urls: { env => "https://orders.test" })
    end
    call("update", "PATCH", -> { "/api/v1/applications/#{app}" }, body: { "name" => "Orders v2" }) do |c|
      c.applications.update(app, name: "Orders v2")
    end
    call("delete", "DELETE", -> { "/api/v1/applications/#{app}" }) { |c| c.applications.delete(app) }
    call("list_environments", "GET", -> { "/api/v1/applications/#{app}/environments" }) do |c|
      c.applications.list_environments(app)
    end
    call("add_environment", "POST", -> { "/api/v1/applications/#{app}/environments" },
         body: -> { { "environment_id" => env, "base_url" => "https://staging.orders.test" } }) do |c|
      c.applications.add_environment(app, environment_id: env, base_url: "https://staging.orders.test")
    end
    call("remove_environment", "DELETE", -> { "/api/v1/applications/#{app}/environments/#{other}" }) do |c|
      c.applications.remove_environment(app, other)
    end
  end

  describe "environments" do
    call("list", "GET", -> { "/api/v1/environments" }) { |c| c.environments.list }
    call("get", "GET", -> { "/api/v1/environments/#{env}" }) { |c| c.environments.get(env) }
    call("create", "POST", -> { "/api/v1/environments" },
         body: { "name" => "staging", "domain" => "staging.test", "is_default" => false }) do |c|
      c.environments.create(name: "staging", domain: "staging.test", is_default: false)
    end
    call("update", "PATCH", -> { "/api/v1/environments/#{env}" }, body: { "domain" => "stg.test" }) do |c|
      c.environments.update(env, domain: "stg.test")
    end
    call("delete", "DELETE", -> { "/api/v1/environments/#{env}" }) { |c| c.environments.delete(env) }
  end

  describe "credentials" do
    call("list", "GET", -> { "/api/v1/credentials" },
         query: { "application_environment_id" => "44444444-4444-4444-8444-444444444444" }) do |c|
      c.credentials.list(application_environment_id: env)
    end
    call("get", "GET", -> { "/api/v1/credentials/#{other}" }) { |c| c.credentials.get(other) }
    call("create", "POST", -> { "/api/v1/credentials" },
         body: -> { { "application_environment_id" => env } }) do |c|
      c.credentials.create(application_environment_id: env)
    end
    call("rotate", "POST", -> { "/api/v1/credentials/#{other}/rotate" }) { |c| c.credentials.rotate(other) }
    call("revoke", "DELETE", -> { "/api/v1/credentials/#{other}" }) { |c| c.credentials.revoke(other) }
  end

  describe "for_managed_client" do
    let(:managed) { client.for_managed_client(cid) }

    call("applications.list", "GET", -> { "/api/v1/clients/#{cid}/applications" }) do |_c|
      managed.applications.list
    end
    call("applications.get", "GET", -> { "/api/v1/clients/#{cid}/applications/#{app}" }) do |_c|
      managed.applications.get(app)
    end
    call("applications.create", "POST", -> { "/api/v1/clients/#{cid}/applications" },
         body: -> { { "name" => "Shop", "environment_base_urls" => { env => "https://shop.test" } } }) do |_c|
      managed.applications.create(name: "Shop", environment_base_urls: { env => "https://shop.test" })
    end
    call("applications.update", "PATCH", -> { "/api/v1/clients/#{cid}/applications/#{app}" },
         body: { "public" => true }) do |_c|
      managed.applications.update(app, public: true)
    end
    call("applications.delete", "DELETE", -> { "/api/v1/clients/#{cid}/applications/#{app}" }) do |_c|
      managed.applications.delete(app)
    end
    call("applications.list_environments", "GET",
         -> { "/api/v1/clients/#{cid}/applications/#{app}/environments" }) do |_c|
      managed.applications.list_environments(app)
    end
    call("applications.add_environment", "POST", -> { "/api/v1/clients/#{cid}/applications/#{app}/environments" },
         body: -> { { "environment_id" => env, "base_url" => "https://shop.test" } }) do |_c|
      managed.applications.add_environment(app, environment_id: env, base_url: "https://shop.test")
    end
    call("applications.remove_environment", "DELETE",
         -> { "/api/v1/clients/#{cid}/applications/#{app}/environments/#{other}" }) do |_c|
      managed.applications.remove_environment(app, other)
    end
    call("environments.list", "GET", -> { "/api/v1/clients/#{cid}/environments" }) do |_c|
      managed.environments.list
    end
    call("environments.get", "GET", -> { "/api/v1/clients/#{cid}/environments/#{env}" }) do |_c|
      managed.environments.get(env)
    end
    call("environments.create", "POST", -> { "/api/v1/clients/#{cid}/environments" },
         body: { "name" => "production", "domain" => "shop.test" }) do |_c|
      managed.environments.create(name: "production", domain: "shop.test")
    end
    call("environments.update", "PATCH", -> { "/api/v1/clients/#{cid}/environments/#{env}" },
         body: { "name" => "prod" }) do |_c|
      managed.environments.update(env, name: "prod")
    end
    call("environments.delete", "DELETE", -> { "/api/v1/clients/#{cid}/environments/#{env}" }) do |_c|
      managed.environments.delete(env)
    end
    call("credentials.list", "GET", -> { "/api/v1/clients/#{cid}/credentials" }) do |_c|
      managed.credentials.list
    end
    call("credentials.get", "GET", -> { "/api/v1/clients/#{cid}/credentials/#{other}" }) do |_c|
      managed.credentials.get(other)
    end
    call("credentials.create", "POST", -> { "/api/v1/clients/#{cid}/credentials" },
         body: -> { { "application_environment_id" => env } }) do |_c|
      managed.credentials.create(application_environment_id: env)
    end
    call("credentials.rotate", "POST", -> { "/api/v1/clients/#{cid}/credentials/#{other}/rotate" }) do |_c|
      managed.credentials.rotate(other)
    end
    call("credentials.delete", "DELETE", -> { "/api/v1/clients/#{cid}/credentials/#{other}" }) do |_c|
      managed.credentials.delete(other)
    end
    call("claim_invite", "POST", -> { "/api/v1/clients/#{cid}/claim_invites" },
         body: { "email" => "owner@acme.test" }) do |_c|
      managed.claim_invite(email: "owner@acme.test")
    end
    call("get", "GET", -> { "/api/v1/clients/#{cid}" }) { |_c| managed.get }
  end

  describe "answers" do
    it "returns a single resource's data" do
      stub_management_api(status: 200, body: { data: { id: pkg, name: "Gold" } })

      expect(client.api_packages.get(pkg)).to eq("id" => pkg, "name" => "Gold")
    end

    it "returns a delete's data" do
      stub_management_api(status: 200, body: { data: { id: pkg, deleted: true } })

      expect(client.api_packages.delete(pkg)).to eq("id" => pkg, "deleted" => true)
    end

    it "returns the whole body of a package endpoint write, so its warnings are not lost" do
      warning = { "code" => "assignment_derives_nothing", "message" => "m", "client_organization_id" => cid,
                  "environment_id" => env }
      stub_management_api(status: 201, body: { data: { id: other }, warnings: [warning] })

      result = client.api_packages.add_endpoint(pkg, application_id: app, environment_id: env)

      expect(result).to eq("data" => { "id" => other }, "warnings" => [warning])
    end

    it "returns a created credential with its one-time client_secret" do
      stub_management_api(status: 201, body: { data: { id: other, client_id: "acme.abc", client_secret: "s3cret" } })

      expect(client.credentials.create(application_environment_id: env)["client_secret"]).to eq("s3cret")
    end
  end

  describe "ids in paths" do
    it "percent-escapes an id so it stays one path segment" do
      stub_management_api

      client.api_packages.get("a/b c?d")

      expect(management_requests.last.path).to eq("/api/v1/api_packages/a%2Fb%20c%3Fd")
    end

    it "refuses an empty or nil id instead of calling the list route" do
      stub_management_api

      expect { client.api_packages.get("") }.to raise_error(ArgumentError)
      expect { client.credentials.delete(nil) }.to raise_error(ArgumentError)
      expect { client.for_managed_client("") }.to raise_error(ArgumentError)
      expect(management_requests).to be_empty
    end
  end
end
