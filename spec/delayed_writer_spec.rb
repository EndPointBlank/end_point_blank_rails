# frozen_string_literal: true

require "spec_helper"
require "end_point_blank/writers/delayed_writer"

RSpec.describe EndPointBlank::Writers::DelayedWriter do
  # A bare double that mixes in the module under test without starting the
  # background drain threads, so we can inspect the queue synchronously.
  let(:writer_class) { Class.new { include EndPointBlank::Writers::DelayedWriter } }
  let(:writer) { writer_class.new }
  let(:max) { EndPointBlank::Writers::DelayedWriter::MAX_QUEUE_SIZE }

  describe "#enqueue" do
    it "bounds the queue at MAX_QUEUE_SIZE" do
      (max + 250).times { |i| writer.enqueue(i) }

      expect(writer.queue.size).to eq(max)
    end

    it "drops the oldest items first, keeping the newest ones" do
      (max + 5).times { |i| writer.enqueue(i) }

      # items 0..4 should have been dropped as the oldest; 5 should be next out
      expect(writer.queue.pop).to eq(5)
    end

    it "accepts everything and keeps FIFO order when under the cap" do
      3.times { |i| writer.enqueue(i) }

      expect(writer.queue.pop).to eq(0)
      expect(writer.queue.pop).to eq(1)
      expect(writer.queue.pop).to eq(2)
    end

    it "logs a throttled warning (not once per drop) when dropping items" do
      allow(writer).to receive(:log_warning)

      (max + 50).times { |i| writer.enqueue(i) }

      expect(writer).to have_received(:log_warning).once
    end

    it "supports enqueueing a list of payloads, still respecting the bound" do
      writer.enqueue((0...(max + 10)).to_a)

      expect(writer.queue.size).to eq(max)
      expect(writer.queue.pop).to eq(10)
    end
  end
end
