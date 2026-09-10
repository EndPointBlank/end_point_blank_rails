# frozen_string_literal: true

require "spec_helper"
require "end_point_blank/writers/delayed_writer"

# rubocop:disable Metrics/BlockLength
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

  describe "#worker_count" do
    after do
      EndPointBlank::Configuration.instance.worker_count = 4
    end

    it "honors EndPointBlank::Configuration.instance.worker_count when set" do
      EndPointBlank::Configuration.instance.worker_count = 7

      expect(writer.worker_count).to eq(7)
    end

    it "falls back to the historical default (2) when worker_count is nil" do
      EndPointBlank::Configuration.instance.worker_count = nil

      expect(writer.worker_count).to eq(EndPointBlank::Writers::DelayedWriter::DEFAULT_WORKER_COUNT)
      expect(writer.worker_count).to eq(2)
    end
  end

  describe "#start_threads" do
    after do
      EndPointBlank::Configuration.instance.worker_count = 4
      writer.instance_variable_get(:@threads)&.each(&:kill)
    end

    it "spawns one thread per configured worker_count" do
      EndPointBlank::Configuration.instance.worker_count = 3

      writer.start_threads

      expect(writer.instance_variable_get(:@threads).size).to eq(3)
    end

    it "spawns the default number of threads when worker_count is nil" do
      EndPointBlank::Configuration.instance.worker_count = nil

      writer.start_threads

      expect(writer.instance_variable_get(:@threads).size)
        .to eq(EndPointBlank::Writers::DelayedWriter::DEFAULT_WORKER_COUNT)
    end
  end

  # sc-376: `queue` and `enqueue_mutex` used to build their memo with a bare
  # `@ivar ||= ...`, which is a read, a nil check, and a write -- not one
  # atomic step. Two threads that both call the accessor before either has
  # written can both observe nil and both allocate: whichever assignment
  # loses leaves the other caller (a worker thread, in production) holding
  # a reference to an orphaned Queue/Mutex that nothing else will ever use.
  #
  # This is inherently a timing-sensitive test. A barrier holds every racer
  # thread at the same starting line and releases them together (via
  # ConditionVariable#broadcast), which maximizes the odds of hitting the
  # narrow window -- it does not guarantee it on every run, and running it
  # once and seeing green proves nothing. So this races many threads across
  # many fresh instances, on the theory that if *any* trial produces two
  # different objects, the accessor is not safe.
  #
  # Importantly: a race test like this can only ever demonstrate the bug's
  # *presence* (by catching two threads with different objects). It cannot
  # prove the bug's *absence* -- a clean run after a fix is evidence the fix
  # works, not proof no interleaving could ever break it.
  describe "concurrent first access to the queue and mutex memoization" do
    let(:racer_count) { 40 }
    let(:trial_count) { 25 }

    def spawn_racers(fresh_writer, barrier, results, reader_method)
      Array.new(racer_count) do
        Thread.new do
          barrier.wait
          results << fresh_writer.send(reader_method)
        end
      end
    end

    def race_once(reader_method)
      results = Queue.new
      threads = spawn_racers(writer_class.new, RaceBarrier.new(racer_count), results, reader_method)
      threads.each(&:join)

      Array.new(racer_count) { results.pop }
    end

    def race(reader_method)
      trial_count.times do
        seen = race_once(reader_method).uniq
        message = "expected every racer to see the same #{reader_method} " \
                  "object, got #{seen.size} distinct objects"

        expect(seen.size).to eq(1), message
      end
    end

    it "gives every thread the same Queue object" do
      race(:queue)
    end

    it "gives every thread the same Mutex object" do
      race(:enqueue_mutex)
    end
  end
end
# rubocop:enable Metrics/BlockLength
