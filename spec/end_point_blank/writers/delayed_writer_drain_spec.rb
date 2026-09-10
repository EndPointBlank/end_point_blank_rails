# frozen_string_literal: true

require "spec_helper"

# The queue is only half the story: these cover what the background workers do
# with what comes off it. Everything runs through the real DirectWriter, with
# Commands::Http stubbed at the network boundary.
#
# rubocop:disable Metrics/BlockLength
RSpec.describe "EndPointBlank::Writers::DelayedWriter draining the queue" do
  let(:configuration) { EndPointBlank::Configuration.instance }
  let(:url) { "https://intake.example.test/api/things" }
  let(:batches) { Queue.new }
  let(:delivery_status) { 200 }

  let(:plain_writer_class) do
    Class.new do
      include EndPointBlank::Writers::DelayedWriter

      attr_reader :url

      def initialize(url)
        @url = url
      end
    end
  end

  let(:reporting_writer_class) do
    Class.new(plain_writer_class) do
      attr_reader :successes, :failures

      def initialize(url)
        super
        @successes = []
        @failures = []
      end

      def on_success(response)
        @successes << response
      end

      def on_failure(response)
        @failures << response
      end
    end
  end

  let(:writer) { plain_writer_class.new(url) }

  around do |example|
    original_workers = configuration.worker_count
    original = %i[@client_id @client_secret].each_with_object({}) do |ivar, memo|
      memo[ivar] = configuration.instance_variable_get(ivar)
    end
    # One worker, so a batch is a batch rather than a race between two threads.
    configuration.worker_count = 1

    example.run

    configuration.worker_count = original_workers
    original.each { |ivar, value| configuration.instance_variable_set(ivar, value) }
  end

  before do
    configuration.client_id = "cid"
    configuration.client_secret = "csecret"
    allow(EndPointBlank::Commands::Http).to receive(:post) do |_url, _auth, body|
      batches << body[:payload]
      double("response", status: delivery_status, body: "{}")
    end
  end

  after do
    writer.instance_variable_get(:@threads)&.each(&:kill)
  end

  def drain(count, timeout: 2)
    deadline = Time.now + timeout
    collected = []
    while collected.size < count && Time.now < deadline
      begin
        collected << batches.pop(true)
      rescue ThreadError
        sleep 0.005
      end
    end
    collected
  end

  # Blocks until the background worker has put something on `queue`, so an
  # assertion about work done off the main thread is a wait rather than a race.
  def take(queue, timeout: 2)
    deadline = Time.now + timeout
    loop do
      return queue.pop(true)
    rescue ThreadError
      raise "nothing arrived on the queue within #{timeout}s" if Time.now > deadline

      sleep 0.005
    end
  end

  def wait_for(timeout: 2)
    deadline = Time.now + timeout
    sleep(0.005) until yield || Time.now > deadline
  end

  # The worker threads report through these; stub them wherever a test provokes
  # a failure on purpose, so the suite does not print the real thing to stderr.
  def silence_worker_logging(target)
    allow(target).to receive(:log_error)
  end

  it "delivers an enqueued payload to the writer's URL" do
    writer.start_threads
    writer.enqueue({ id: 1 })

    expect(drain(1)).to eq([[{ id: 1 }]])
    expect(EndPointBlank::Commands::Http).to have_received(:post).with(url, anything, anything)
  end

  # One request per payload would multiply the host application's outbound
  # traffic by its own request rate; the drain exists to amortise that.
  it "sends payloads that are already waiting together, six at a time" do
    10.times { |i| writer.enqueue({ id: i }) }

    writer.start_threads

    expect(drain(2).map(&:size)).to eq([6, 4])
  end

  # `payloads -= list` removed every element *equal to* one in the batch rather
  # than the ones actually sent, so a queue holding duplicates lost the extras
  # without sending them and without saying so. Payloads are hashes: two
  # requests to the same endpoint, from the same application, in the same
  # environment differ only in high-cardinality fields, and `sent_at` at
  # millisecond precision does not reliably separate them at ingest volumes.
  context "when the queue holds byte-identical payloads" do
    it "delivers every one of them, not one per distinct value" do
      7.times { writer.enqueue({ id: :same }) }

      writer.start_threads

      expect(drain(2).flatten.size).to eq(7)
    end

    it "batches them by position, so the seventh follows the first six" do
      7.times { writer.enqueue({ id: :same }) }

      writer.start_threads

      expect(drain(2).map(&:size)).to eq([6, 1])
    end

    # More than two batches, so this is not a one-off remainder: nothing is
    # lost at any boundary.
    it "keeps delivering duplicates across every batch of a long run" do
      13.times { writer.enqueue({ id: :same }) }

      writer.start_threads

      expect(drain(3).map(&:size)).to eq([6, 6, 1])
    end

    # The values are equal but the count is what matters, so assert the count
    # rather than the set: `uniq` would hide exactly the defect under test.
    it "sends duplicates that are mixed in among distinct payloads" do
      writer.enqueue({ id: :a })
      5.times { writer.enqueue({ id: :same }) }
      writer.enqueue({ id: :b })
      writer.enqueue({ id: :same })

      writer.start_threads

      expect(drain(2).flatten).to eq(
        [{ id: :a }] + Array.new(5) { { id: :same } } + [{ id: :b }, { id: :same }]
      )
    end
  end

  it "tells a writer that asks about a successful delivery" do
    reporting = reporting_writer_class.new(url)
    reporting.start_threads
    reporting.enqueue({ id: 1 })
    drain(1)

    expect(reporting.successes.size).to eq(1)
    reporting.instance_variable_get(:@threads).each(&:kill)
  end

  context "when the intake rejects the batch" do
    let(:delivery_status) { 500 }

    it "tells a writer that asks about a failed delivery" do
      reporting = reporting_writer_class.new(url)
      reporting.start_threads
      reporting.enqueue({ id: 1 })
      drain(1)

      expect(reporting.failures.size).to eq(1)
      reporting.instance_variable_get(:@threads).each(&:kill)
    end

    it "does not require a writer to implement either callback" do
      writer.start_threads

      expect { writer.enqueue({ id: 1 }) }.not_to raise_error
      expect(drain(1)).to eq([[{ id: 1 }]])
    end
  end

  # Commands::Http returns nil once its retries are exhausted. That is not a
  # status, it is the absence of an answer, and the worker used to call
  # `.status` on it.
  context "when nothing answers at all" do
    before { allow(EndPointBlank::Commands::Http).to receive(:post).and_return(nil) }

    it "keeps draining after the intake becomes unreachable" do
      silence_worker_logging(writer)
      writer.start_threads
      writer.enqueue({ id: :lost })
      sleep 0.05

      allow(EndPointBlank::Commands::Http).to receive(:post) do |_url, _auth, body|
        batches << body[:payload]
        double("response", status: 200, body: "{}")
      end
      writer.enqueue({ id: :next })

      expect(drain(1, timeout: 1)).to eq([[{ id: :next }]])
    end

    it "hands the missing answer to a writer that asks about failures" do
      reporting = reporting_writer_class.new(url)
      silence_worker_logging(reporting)
      reporting.start_threads
      reporting.enqueue({ id: 1 })

      wait_for { reporting.failures.any? }
      expect(reporting.failures).to eq([nil])
      reporting.instance_variable_get(:@threads).each(&:kill)
    end

    it "says which batch it lost rather than dropping it quietly" do
      logged = Queue.new
      allow(writer).to receive(:log_error) { |message| logged << message }
      writer.start_threads
      writer.enqueue({ id: 1 })

      expect(take(logged)).to include("no response from #{url}", "1 payload(s)")
    end

    it "does not require a writer to implement either callback" do
      silence_worker_logging(writer)
      writer.start_threads
      writer.enqueue({ id: 1 })
      sleep 0.05

      expect(writer.instance_variable_get(:@threads)).to all(be_alive)
    end
  end

  # The nil above is one defect of a shape that has bitten this writer three
  # times. The loop has to outlive the next one too, whatever it turns out to
  # be: a dead worker loses every payload for the life of the process, which is
  # far worse than losing the batch in flight.
  context "when the send path raises something the loop never expected" do
    let(:original_reporting) { Thread.report_on_exception }

    before do
      original_reporting
      Thread.report_on_exception = false
    end

    after { Thread.report_on_exception = original_reporting }

    it "keeps draining" do
      silence_worker_logging(writer)
      calls = 0
      allow(EndPointBlank::Commands::Http).to receive(:post) do |_url, _auth, body|
        calls += 1
        raise "intake exploded" if calls == 1

        batches << body[:payload]
        double("response", status: 200, body: "{}")
      end

      writer.start_threads
      writer.enqueue({ id: :lost })
      sleep 0.05
      writer.enqueue({ id: :next })

      expect(drain(1, timeout: 2)).to eq([[{ id: :next }]])
    end

    it "logs what it recovered from, and counts how long it has been failing" do
      logged = Queue.new
      allow(writer).to receive(:log_error) { |message| logged << message }
      allow(EndPointBlank::Commands::Http).to receive(:post).and_raise("intake exploded")

      writer.start_threads
      writer.enqueue({ id: 1 })
      first = take(logged)
      writer.enqueue({ id: 2 })
      second = take(logged)

      expect(first).to include("RuntimeError", "intake exploded", "consecutive failure 1")
      expect(second).to include("consecutive failure 2")
    end

    # Surviving must not mean retrying as fast as the CPU allows: that is a
    # silent failure with a fan attached.
    it "backs off instead of retrying in a hot loop" do
      silence_worker_logging(writer)
      attempts = Queue.new
      allow(EndPointBlank::Commands::Http).to receive(:post) do
        attempts << Time.now
        raise "intake exploded"
      end

      writer.enqueue({ id: :warmup })
      writer.start_threads
      feeder = Thread.new do
        250.times do
          writer.enqueue({ id: :more })
          sleep 0.002
        end
      end
      sleep 0.5
      feeder.kill

      expect(attempts.size).to be_between(2, 25)
    end

    # StandardError is caught; an Exception that is not one means the process
    # itself is going down, and a telemetry worker must not argue with that.
    it "still lets a process-level error end the thread" do
      silence_worker_logging(writer)
      allow(EndPointBlank::Commands::Http).to receive(:post).and_raise(Interrupt)

      writer.start_threads
      writer.enqueue({ id: 1 })

      thread = writer.instance_variable_get(:@threads).first
      wait_for { !thread.alive? }
      expect(thread).not_to be_alive
    end
  end
end
# rubocop:enable Metrics/BlockLength
