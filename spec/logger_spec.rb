# frozen_string_literal: true

require "spec_helper"
require "end_point_blank/loggers/logger"
require "stringio"

RSpec.shared_context "resets EndPointBlank logger state" do
  # Configuration is a singleton and EndPointBlank.logger memoizes a default
  # logger instance, so both must be reset between examples to avoid leaking
  # state across specs.
  around do |example|
    original_logger = EndPointBlank::Configuration.instance.logger
    EndPointBlank.instance_variable_set(:@default_logger, nil)

    example.run

    EndPointBlank::Configuration.instance.logger = original_logger
    EndPointBlank.instance_variable_set(:@default_logger, nil)
  end
end

RSpec.describe "EndPointBlank.logger" do
  include_context "resets EndPointBlank logger state"

  it "returns a stdout Logger when ::Rails is not defined and no logger is configured" do
    expect(defined?(::Rails)).to be_falsey

    expect(EndPointBlank.logger).to be_a(::Logger)
  end

  it "memoizes the default logger across calls" do
    expect(EndPointBlank.logger).to equal(EndPointBlank.logger)
  end

  it "honors a logger set via EndPointBlank.configure" do
    custom_logger = ::Logger.new(StringIO.new)

    EndPointBlank.configure { |c| c.logger = custom_logger }

    expect(EndPointBlank.logger).to equal(custom_logger)
  end

  it "supports EndPointBlank.logger= directly" do
    custom_logger = ::Logger.new(StringIO.new)

    EndPointBlank.logger = custom_logger

    expect(EndPointBlank.logger).to equal(custom_logger)
  end
end

RSpec.describe EndPointBlank::Loggers::Logger do
  include_context "resets EndPointBlank logger state"

  let(:spy_logger) { double("logger", error: nil, warn: nil, fatal: nil) }

  before { EndPointBlank.logger = spy_logger }

  it "routes .error through EndPointBlank.logger" do
    described_class.error("boom")

    expect(spy_logger).to have_received(:error).with("boom")
  end

  it "routes .warn through EndPointBlank.logger" do
    described_class.warn("careful")

    expect(spy_logger).to have_received(:warn).with("careful")
  end

  it "routes .fatal through EndPointBlank.logger" do
    described_class.fatal("bad")

    expect(spy_logger).to have_received(:fatal).with("bad")
  end
end
