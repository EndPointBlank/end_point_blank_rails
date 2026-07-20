# frozen_string_literal: true

require "spec_helper"

RSpec.describe EndPointBlank::Rack::Headers do
  after { EndPointBlank::Rack::EnvStore.clear }

  it "returns {} when no rack env is set (empty EnvStore), instead of crashing" do
    EndPointBlank::Rack::EnvStore.clear
    expect(described_class.extract).to eq({})
  end

  it "extracts HTTP_ headers into title-cased keys when the env is set" do
    EndPointBlank::Rack::EnvStore.set(
      "HTTP_X_REQUEST_ID" => "abc",
      "PATH_INFO" => "/ignored"
    )
    expect(described_class.extract).to eq("X-Request-Id" => "abc")
  end
end
