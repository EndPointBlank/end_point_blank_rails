# frozen_string_literal: true

require "spec_helper"

RSpec.describe EndPointBlank::LogEntry do
  def build(**overrides)
    described_class.new(
      **{ message: "boom", env: { "PATH_INFO" => "/x" }, stacktrace: ["a.rb:1"], app: "app",
          status: 500, headers: { "Accept" => "application/json" }, body: "body" }.merge(overrides)
    )
  end

  it "carries every field it was built with" do
    entry = build

    expect(entry.message).to eq("boom")
    expect(entry.env).to eq("PATH_INFO" => "/x")
    expect(entry.stacktrace).to eq(["a.rb:1"])
    expect(entry.app).to eq("app")
    expect(entry.status).to eq(500)
    expect(entry.headers).to eq("Accept" => "application/json")
    expect(entry.body).to eq("body")
  end

  # The intake orders records by when they happened, so an entry that is built
  # now and sent later still has to say when it was built.
  it "stamps itself with the time it was built" do
    expect(build.sent_at).to be_within(5).of(Time.now)
  end

  it "accepts a caller-supplied timestamp" do
    at = Time.now - 3600

    expect(build(sent_at: at).sent_at).to eq(at)
  end

  # A stacktrace is an array of frames on every EndPointBlank client library;
  # flattening it to a string here would make this SDK's error records the odd
  # one out in the portal.
  it "keeps a stacktrace as an array of frames" do
    expect(build(stacktrace: %w[a.rb:1 b.rb:2]).stacktrace).to eq(%w[a.rb:1 b.rb:2])
  end
end
