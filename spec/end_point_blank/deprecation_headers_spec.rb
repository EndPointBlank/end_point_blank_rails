# frozen_string_literal: true

require "spec_helper"

# The vectors below are the shared set from
# docs/superpowers/specs/2026-08-01-header-vectors.md in app_portal. The same
# table is asserted in every SDK, so a Ruby date format that differs from the
# Python one by a leading zero is a test failure here rather than a subtly
# non-compliant header a customer finds.
#
# Row 1 is RFC 9745's own worked example. It is the reason to trust the rest.
RSpec.describe EndPointBlank::DeprecationHeaders do
  VECTORS = [
    ["2023-06-30T23:59:59Z", "@1688169599", "Fri, 30 Jun 2023 23:59:59 GMT"],
    ["2026-01-01T00:00:00Z", "@1767225600", "Thu, 01 Jan 2026 00:00:00 GMT"],
    ["2026-03-09T05:00:00Z", "@1773032400", "Mon, 09 Mar 2026 05:00:00 GMT"],
    ["2026-08-01T14:15:16Z", "@1785593716", "Sat, 01 Aug 2026 14:15:16 GMT"],
    ["2026-11-11T11:11:11Z", "@1794395471", "Wed, 11 Nov 2026 11:11:11 GMT"]
  ].freeze

  describe "the shared vectors" do
    VECTORS.each do |iso, deprecation, sunset|
      it "formats #{iso} to #{deprecation} and #{sunset}" do
        headers = described_class.build("deprecated_at" => iso, "sunset_at" => iso)

        expect(headers["Deprecation"]).to eq(deprecation)
        expect(headers["Sunset"]).to eq(sunset)
      end
    end
  end

  describe "RFC conformance details" do
    it "zero-pads the day of month" do
      headers = described_class.build("sunset_at" => "2026-01-01T00:00:00Z")
      expect(headers["Sunset"]).to include(" 01 Jan ")
    end

    it "always says GMT, never UTC or an offset" do
      headers = described_class.build("sunset_at" => "2026-01-01T00:00:00Z")
      expect(headers["Sunset"]).to end_with(" GMT")
      expect(headers["Sunset"]).not_to include("UTC")
      expect(headers["Sunset"]).not_to include("+00")
    end

    it "converts a non-UTC input before formatting rather than relabelling it" do
      # 2026-01-01T00:00:00+02:00 is 2025-12-31T22:00:00Z.
      headers = described_class.build("sunset_at" => "2026-01-01T00:00:00+02:00")
      expect(headers["Sunset"]).to eq("Wed, 31 Dec 2025 22:00:00 GMT")
    end

    it "emits the Deprecation value unquoted and without sub-second precision" do
      headers = described_class.build("deprecated_at" => "2023-06-30T23:59:59.750Z")
      expect(headers["Deprecation"]).to eq("@1688169599")
    end
  end

  describe "partial and absent input" do
    it "emits Deprecation alone when there is no sunset date" do
      # The normal starting state: going away, no deadline committed yet.
      headers = described_class.build("deprecated_at" => "2026-01-01T00:00:00Z", "sunset_at" => nil)

      expect(headers).to have_key("Deprecation")
      expect(headers).not_to have_key("Sunset")
    end

    it "returns nothing for nil" do
      expect(described_class.build(nil)).to eq({})
    end

    it "returns nothing for an empty hash" do
      expect(described_class.build({})).to eq({})
    end

    it "accepts symbol keys as well as string keys" do
      headers = described_class.build(deprecated_at: "2026-01-01T00:00:00Z")
      expect(headers["Deprecation"]).to eq("@1767225600")
    end
  end

  describe "never raising into the response path" do
    # A bad header is a bug. A 500 on a request that already succeeded is an
    # outage, and this code runs on every authorized response.
    it "ignores a malformed timestamp" do
      expect(described_class.build("deprecated_at" => "not a date")).to eq({})
    end

    it "ignores a non-string, non-time value" do
      expect(described_class.build("deprecated_at" => 12_345)).to eq({})
    end

    it "ignores a non-hash block" do
      expect(described_class.build("nonsense")).to eq({})
      expect(described_class.build([1, 2, 3])).to eq({})
    end

    it "still emits the good half when only one timestamp is bad" do
      headers = described_class.build(
        "deprecated_at" => "2026-01-01T00:00:00Z",
        "sunset_at" => "garbage"
      )

      expect(headers["Deprecation"]).to eq("@1767225600")
      expect(headers).not_to have_key("Sunset")
    end
  end
end
