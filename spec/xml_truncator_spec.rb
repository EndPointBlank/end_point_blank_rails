# frozen_string_literal: true

require "spec_helper"

# rubocop:disable Metrics/BlockLength
RSpec.describe XmlTruncator do
  it "returns an empty string for nil" do
    expect(described_class.truncate(nil)).to eq("")
  end

  it "returns an empty string for an empty document" do
    expect(described_class.truncate("")).to eq("")
  end

  it "leaves a document that is already within the limit untouched" do
    xml = "<root><item>value</item></root>"

    expect(described_class.truncate(xml, limit: 1000)).to eq(xml)
  end

  describe "pruning an oversized document" do
    let(:many_children) { "<root>#{(1..50).map { |i| "<item>value#{i}</item>" }.join}</root>" }

    it "keeps at most MAX_CHILDREN elements and says the rest were dropped" do
      result = described_class.truncate(many_children, limit: 500)

      expect(result.scan("<item>").size).to eq(described_class::MAX_CHILDREN)
      expect(result).to include("<truncated/>")
    end

    it "keeps at most MAX_ATTRIBUTES attributes" do
      xml = "<root #{(1..40).map { |i| "attr#{i}='value#{i}'" }.join(" ")}><x/></root>"

      result = described_class.truncate(xml, limit: 400)

      expect(result.scan(/attr\d+=/).size).to eq(described_class::MAX_ATTRIBUTES)
    end

    it "stops descending at MAX_DEPTH and marks where it stopped" do
      xml = ("<a>" * 10) + "leaf" + ("</a>" * 10)

      result = described_class.truncate(xml, limit: 65)

      # The root plus MAX_DEPTH levels below it; everything deeper is dropped.
      expect(result.scan("<a>").size).to eq(described_class::MAX_DEPTH + 1)
      expect(result).to include("<truncated/>")
      expect(result).not_to include("leaf")
    end

    it "shortens a long text node and marks it" do
      xml = "<root><note>#{"z" * 5000}</note></root>"

      result = described_class.truncate(xml, limit: 400)

      expect(result).to include("#{"z" * (described_class::MAX_TEXT - 3)}...")
    end

    it "keeps CDATA as CDATA rather than flattening it into text" do
      # CDATA exists to hold content that would otherwise need escaping;
      # re-emitting it as plain text produces a document that will not parse.
      xml = "<root><![CDATA[#{"y" * 400}]]></root>"

      result = described_class.truncate(xml, limit: 300)

      expect(result).to include("<![CDATA[")
      expect(result).to include("]]>")
    end

    it "produces a document that still parses" do
      result = described_class.truncate(many_children, limit: 500)

      expect { REXML::Document.new(result) }.not_to raise_error
    end
  end

  describe "when pruning is not enough" do
    let(:huge_text) { "<root><note>#{"z" * 5000}</note></root>" }

    it "falls back to an empty document with the same root element" do
      expect(described_class.truncate(huge_text, limit: 30)).to eq("<root><truncated/></root>")
    end

    it "falls back to a bare marker when even the root element will not fit" do
      expect(described_class.truncate(huge_text, limit: 10)).to eq("<truncated/>")
    end
  end

  describe "malformed input" do
    # Bodies are captured off the wire, so they are not guaranteed to be
    # well-formed XML. Losing the payload entirely would be worse than
    # recording a byte-truncated copy of what actually arrived.
    it "falls back to a byte truncation of the raw text" do
      xml = "<root><unclosed>#{"x" * 300}"

      result = described_class.truncate(xml, limit: 60)

      expect(result).to start_with("<root><unclosed>")
      expect(result).to end_with("<truncated/>")
      expect(result.bytesize).to eq(60)
    end
  end
end
# rubocop:enable Metrics/BlockLength
