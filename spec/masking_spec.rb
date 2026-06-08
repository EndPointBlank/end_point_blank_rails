require "spec_helper"
require "end_point_blank/masking"

RSpec.describe EndPointBlank::Masking do
  def rule(target:, path: nil, regex: nil, replacement: "...")
    { target: target, path: path, regex: regex, replacement_value: replacement }
  end

  describe "reference vectors" do
    it "path only: $.user.ssn replaces entirely" do
      payload = { request: '{"user":{"ssn":"abc"}}' }
      out = described_class.apply(payload, :request, [rule(target: "request_body", path: "$.user.ssn", replacement: "***")], nil)
      expect(JSON.parse(out[:request])).to eq("user" => { "ssn" => "***" })
    end

    it "path only: $..password recursive descent masks all" do
      payload = { request: '{"a":{"password":1},"b":{"password":2}}' }
      out = described_class.apply(payload, :request, [rule(target: "request_body", path: "$..password", replacement: "***")], nil)
      expect(JSON.parse(out[:request])).to eq("a" => { "password" => "***" }, "b" => { "password" => "***" })
    end

    it "path + regex: regex applies within the selected node" do
      payload = { request: '{"note":"ssn 123-45-6789"}' }
      out = described_class.apply(payload, :request, [rule(target: "request_body", path: "$.note", regex: '\d{3}-\d{2}-\d{4}', replacement: "XXX")], nil)
      expect(JSON.parse(out[:request])).to eq("note" => "ssn XXX")
    end

    it "regex only: substitutes only matching string leaves" do
      payload = { request: '{"a":"x 123-45-6789","b":"y"}' }
      out = described_class.apply(payload, :request, [rule(target: "request_body", regex: '\d{3}-\d{2}-\d{4}', replacement: "XXX")], nil)
      expect(JSON.parse(out[:request])).to eq("a" => "x XXX", "b" => "y")
    end

    it "path only: $.list[*].k wildcard masks all elements" do
      payload = { request: '{"list":[{"k":"p"},{"k":"q"}]}' }
      out = described_class.apply(payload, :request, [rule(target: "request_body", path: "$.list[*].k", replacement: "_")], nil)
      expect(JSON.parse(out[:request])).to eq("list" => [{ "k" => "_" }, { "k" => "_" }])
    end

    it "path no-op on a plain (non-JSON path target) string" do
      payload = { path: "123-45-6789" }
      out = described_class.apply(payload, :request, [rule(target: "path", path: "$.x", replacement: "_")], nil)
      expect(out[:path]).to eq("123-45-6789")
    end
  end

  describe "target / wire-key resolution" do
    it "masks a response body (wire key :body)" do
      payload = { body: '{"email":"a@b.com"}' }
      out = described_class.apply(payload, :response, [rule(target: "response_body", path: "$.email")], nil)
      expect(JSON.parse(out[:body])).to eq("email" => "...")
    end

    it "masks error_message (wire key :message) with regex" do
      payload = { message: "boom a@b.com here" }
      out = described_class.apply(payload, :error, [rule(target: "error_message", regex: '[\w.]+@[\w.]+', replacement: "...")], nil)
      expect(out[:message]).to eq("boom ... here")
    end

    it "does not touch request fields for an error record" do
      payload = { request: '{"email":"a@b.com"}' }
      out = described_class.apply(payload, :error, [rule(target: "request_body", path: "$.email")], nil)
      expect(out[:request]).to eq('{"email":"a@b.com"}')
    end

    it "regex-masks the URL path substring" do
      payload = { path: "/users/a@b.com/x" }
      out = described_class.apply(payload, :request, [rule(target: "path", regex: '[\w.]+@[\w.]+', replacement: "...")], nil)
      expect(out[:path]).to eq("/users/.../x")
    end
  end

  describe "request_headers (Hash value)" do
    it "path masks a header value entirely" do
      payload = { headers: { "Authorization" => "Bearer x", "X-Trace" => "ok" } }
      out = described_class.apply(payload, :request, [rule(target: "request_headers", path: "$.Authorization")], nil)
      expect(out[:headers]).to eq("Authorization" => "...", "X-Trace" => "ok")
    end

    it "regex masks across header string values" do
      payload = { headers: { "Authorization" => "Bearer abc123", "X-Trace" => "ok" } }
      out = described_class.apply(payload, :request, [rule(target: "request_headers", regex: 'abc\d+', replacement: "[X]")], nil)
      expect(out[:headers]).to eq("Authorization" => "Bearer [X]", "X-Trace" => "ok")
    end

    it "path is case-sensitive on header keys" do
      payload = { headers: { "Authorization" => "Bearer x" } }
      out = described_class.apply(payload, :request, [rule(target: "request_headers", path: "$.authorization")], nil)
      expect(out[:headers]).to eq("Authorization" => "Bearer x")
    end
  end

  describe "non-JSON body" do
    it "leaves a non-JSON body unchanged for a path rule" do
      payload = { request: "not json a@b.com" }
      out = described_class.apply(payload, :request, [rule(target: "request_body", path: "$.email")], nil)
      expect(out[:request]).to eq("not json a@b.com")
    end

    it "applies regex to a non-JSON body raw string" do
      payload = { request: "not json a@b.com" }
      out = described_class.apply(payload, :request, [rule(target: "request_body", regex: '[\w.]+@[\w.]+', replacement: "...")], nil)
      expect(out[:request]).to eq("not json ...")
    end
  end

  describe "no-op guards" do
    it "no path and no regex is a no-op" do
      payload = { request: '{"email":"a@b.com"}' }
      out = described_class.apply(payload, :request, [rule(target: "request_body")], nil)
      expect(out[:request]).to eq('{"email":"a@b.com"}')
    end

    it "invalid/garbled path is a no-op, never raises" do
      payload = { request: '{"email":"a@b.com"}' }
      out = described_class.apply(payload, :request, [rule(target: "request_body", path: "$[?(@.x)]")], nil)
      expect(out[:request]).to eq('{"email":"a@b.com"}')
    end

    it "out-of-range array index is a no-op" do
      payload = { request: '{"list":["a"]}' }
      out = described_class.apply(payload, :request, [rule(target: "request_body", path: "$.list[5]")], nil)
      expect(out[:request]).to eq('{"list":["a"]}')
    end

    it "missing key is a no-op" do
      payload = { request: '{"a":1}' }
      out = described_class.apply(payload, :request, [rule(target: "request_body", path: "$.b")], nil)
      expect(JSON.parse(out[:request])).to eq("a" => 1)
    end
  end

  describe "hook" do
    it "runs the hook after the rules" do
      payload = { request: '{"email":"a@b.com"}' }
      hook = ->(p, _type) { p.merge(extra: "added") }
      out = described_class.apply(payload, :request, [rule(target: "request_body", path: "$.email")], hook)
      expect(out[:extra]).to eq("added")
      expect(JSON.parse(out[:request])).to eq("email" => "...")
    end

    it "passes record_type as a string to the hook" do
      seen = nil
      hook = ->(p, type) { seen = type; p }
      described_class.apply({ request: "x" }, :request, [], hook)
      expect(seen).to eq("request")
    end
  end

  describe "writers emit real wire keys" do
    it "FIELD_MAP points at the real symbol wire keys" do
      expect(described_class::FIELD_MAP[:request]).to eq("request_body" => :request, "request_headers" => :headers, "path" => :path)
      expect(described_class::FIELD_MAP[:response]).to eq("response_body" => :body)
      expect(described_class::FIELD_MAP[:error]).to eq("error_message" => :message)
    end
  end

  describe "JSONPath parser" do
    it "parses bracketed quoted child names with special chars" do
      payload = { request: '{"a.b":{"x":1}}' }
      out = described_class.apply(payload, :request, [rule(target: "request_body", path: "$['a.b'].x", replacement: "Z")], nil)
      expect(JSON.parse(out[:request])).to eq("a.b" => { "x" => "Z" })
    end

    it "parses [n] array index" do
      payload = { request: '{"list":["a","b","c"]}' }
      out = described_class.apply(payload, :request, [rule(target: "request_body", path: "$.list[1]", replacement: "Z")], nil)
      expect(JSON.parse(out[:request])).to eq("list" => ["a", "Z", "c"])
    end

    it "wildcard over object values" do
      payload = { request: '{"m":{"a":"1","b":"2"}}' }
      out = described_class.apply(payload, :request, [rule(target: "request_body", path: "$.m.*", replacement: "Z")], nil)
      expect(JSON.parse(out[:request])).to eq("m" => { "a" => "Z", "b" => "Z" })
    end
  end
end
