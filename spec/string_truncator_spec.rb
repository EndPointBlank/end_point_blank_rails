# frozen_string_literal: true

require "spec_helper"

RSpec.describe StringTruncator do
  it "returns an empty string for nil" do
    expect(described_class.truncate(nil)).to eq("")
  end

  it "leaves a string that is already within the limit untouched" do
    expect(described_class.truncate("short", limit: 100)).to eq("short")
  end

  it "leaves a string exactly at the limit untouched" do
    expect(described_class.truncate("a" * 50, limit: 50)).to eq("a" * 50)
  end

  it "marks a truncated string so a reader knows the payload is incomplete" do
    result = described_class.truncate("a" * 100, limit: 50)

    expect(result).to end_with(described_class::DEFAULT_SUFFIX)
    expect(result).to start_with("a")
  end

  # The limit is a byte budget: whatever is downstream sized its column or its
  # request body around it, so the suffix has to fit inside it, not extend it.
  it "keeps the result within the byte limit, suffix included" do
    result = described_class.truncate("a" * 100, limit: 50)

    expect(result.bytesize).to eq(50)
  end

  it "accepts a caller-supplied suffix" do
    result = described_class.truncate("a" * 100, limit: 50, suffix: "…snip")

    expect(result).to end_with("…snip")
    expect(result.bytesize).to be <= 50
  end

  describe "multi-byte text" do
    # Cutting a string at a byte offset lands mid-character often enough to
    # matter, and an invalid-UTF-8 payload is rejected wholesale by the intake
    # rather than merely arriving truncated.
    it "never produces invalid UTF-8, even when the byte limit falls mid-character" do
      long = "é" * 40

      (20..40).each do |limit|
        expect(described_class.truncate(long, limit: limit)).to be_valid_encoding
      end
    end

    it "drops the partial character rather than keeping half of it" do
      result = described_class.truncate("é" * 40, limit: 26)

      expect(result).to eq(("é" * 7) + described_class::DEFAULT_SUFFIX)
    end
  end
end
