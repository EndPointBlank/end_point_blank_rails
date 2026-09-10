# frozen_string_literal: true

require "spec_helper"

# sc-377: request_uuid(env) used to return nil whenever
# env["action_dispatch.request_id"] was unset -- true for every row outside
# Rails (plain Rack / Sinatra never sets that key, and EnvStore never mints a
# uuid), not just outside a request. intake requires uuid on every
# error/log/request/response row and refuses rows that lack it, so a nil
# uuid was a silently dropped row.
RSpec.describe EndPointBlank::Writers::Shared do
  # Shared is a module of instance methods; any Writer singleton includes it.
  let(:includer) { EndPointBlank::Writers::ExceptionWriter.instance }

  describe "#request_uuid" do
    it "reads the Rails/ActionDispatch request id when present" do
      env = { "action_dispatch.request_id" => "abc-123" }

      expect(includer.request_uuid(env)).to eq("abc-123")
    end

    it "mints a uuid when the env has no request id (plain Rack / Sinatra)" do
      env = { "REQUEST_METHOD" => "GET" }

      expect(includer.request_uuid(env)).to match(/\A[0-9a-f-]{36}\z/)
    end

    it "mints a uuid when env itself is nil (outside any request)" do
      expect(includer.request_uuid(nil)).to match(/\A[0-9a-f-]{36}\z/)
    end

    it "never returns nil, since intake refuses a row without a uuid" do
      expect(includer.request_uuid(nil)).not_to be_nil
      expect(includer.request_uuid({})).not_to be_nil
    end
  end
end
