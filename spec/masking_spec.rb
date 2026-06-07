require "spec_helper"
require "end_point_blank/masking"

RSpec.describe EndPointBlank::Masking do
  def key_rule(value, targets, mask = "...")
    { match_type: "key", match_value: value, targets: targets, mask_value: mask }
  end

  def regex_rule(source, targets, mask = "...")
    { match_type: "regex", match_value: source, targets: targets, mask_value: mask }
  end

  it "masks a matching header value case-insensitively" do
    payload = { headers: { "Authorization" => "Bearer x", "X-Trace" => "ok" } }
    out = described_class.apply(payload, :request, [key_rule("authorization", ["request_headers"])], nil)
    expect(out[:headers]).to eq("Authorization" => "...", "X-Trace" => "ok")
  end

  it "masks matching keys in a JSON request body at any depth" do
    payload = { request: '{"user":{"email":"a@b.com"},"items":[{"email":"c@d.com"}]}' }
    out = described_class.apply(payload, :request, [key_rule("email", ["request_body"], "[X]")], nil)
    expect(JSON.parse(out[:request])).to eq("user" => { "email" => "[X]" }, "items" => [{ "email" => "[X]" }])
  end

  it "leaves a non-JSON body unchanged for a key rule" do
    payload = { request: "not json a@b.com" }
    out = described_class.apply(payload, :request, [key_rule("email", ["request_body"])], nil)
    expect(out[:request]).to eq("not json a@b.com")
  end

  it "regex-masks the path substring" do
    payload = { path: "/users/a@b.com/x" }
    out = described_class.apply(payload, :request, [regex_rule('[\w.]+@[\w.]+', ["path"])], nil)
    expect(out[:path]).to eq("/users/.../x")
  end

  it "masks a response body (wire key :body)" do
    payload = { body: '{"email":"a@b.com"}' }
    out = described_class.apply(payload, :response, [key_rule("email", ["response_body"])], nil)
    expect(JSON.parse(out[:body])).to eq("email" => "...")
  end

  it "does not touch request fields for an error record" do
    payload = { request: '{"email":"a@b.com"}' }
    out = described_class.apply(payload, :error, [key_rule("email", ["request_body"])], nil)
    expect(out[:request]).to eq('{"email":"a@b.com"}')
  end

  it "runs the hook after the rules" do
    payload = { request: '{"email":"a@b.com"}' }
    hook = ->(p, _type) { p.merge(extra: "added") }
    out = described_class.apply(payload, :request, [key_rule("email", ["request_body"])], hook)
    expect(out[:extra]).to eq("added")
    expect(JSON.parse(out[:request])).to eq("email" => "...")
  end
end
