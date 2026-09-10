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

    it "returns the same minted uuid on every call for the same env (plain Rack / Sinatra)" do
      # RequestWriter and ResponseWriter both call `request_uuid(env)` with the
      # *same* env object for one HTTP request -- EnvStore.set(env) is called
      # once, at the top of the middleware, and EnvStore.get hands back that
      # same object to every writer for the life of the request.
      #
      # Under Rails that is enough on its own: action_dispatch.request_id is
      # set once and read many times. Under plain Rack there is no such key,
      # so without memoization each call minted a *fresh* uuid -- the request
      # row and the response row for one interaction got two different,
      # unrelated ids. That silently defeats the exact correlation these
      # columns exist for, on every single request, for any non-Rails caller.
      env = { "REQUEST_METHOD" => "GET" }

      first = includer.request_uuid(env)
      second = includer.request_uuid(env)

      expect(second).to eq(first)
    end

    it "does not leak a cached uuid onto an env that already carries a real request id" do
      # Reading first with no request_id present must not poison a later read
      # of a *different* env that legitimately has one.
      includer.request_uuid({})

      env = { "action_dispatch.request_id" => "real-id" }
      expect(includer.request_uuid(env)).to eq("real-id")
    end
  end
end
