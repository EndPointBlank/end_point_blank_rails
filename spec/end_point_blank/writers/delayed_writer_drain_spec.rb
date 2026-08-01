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

  it "keeps draining after the intake becomes unreachable" do
    pending(
      "BUG: Commands::Http.post returns nil when the intake cannot be reached, and the worker loop calls " \
      "response.status on it unguarded. The NoMethodError escapes `loop do` and silently kills the worker " \
      "thread, so the writer stops delivering anything for the rest of the process's life."
    )

    original_reporting = Thread.report_on_exception
    Thread.report_on_exception = false

    allow(EndPointBlank::Commands::Http).to receive(:post).and_return(nil)
    writer.start_threads
    writer.enqueue({ id: :lost })
    sleep 0.05

    allow(EndPointBlank::Commands::Http).to receive(:post) do |_url, _auth, body|
      batches << body[:payload]
      double("response", status: 200, body: "{}")
    end
    writer.enqueue({ id: :next })

    expect(drain(1, timeout: 0.5)).to eq([[{ id: :next }]])
  ensure
    Thread.report_on_exception = original_reporting
  end
end
# rubocop:enable Metrics/BlockLength
