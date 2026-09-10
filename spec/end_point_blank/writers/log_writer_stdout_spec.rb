# frozen_string_literal: true

require "spec_helper"
require "stringio"

# LogWriter#write used to `puts` the full payload -- message, caller-supplied
# `data`, everything -- to the host application's own stdout on every single
# write, unconditionally, with no config flag guarding it.
#
# It did this *before* any masking could apply: LogWriter never calls
# Shared#apply_masking at all (unlike RequestWriter, ResponseWriter and
# ExceptionWriter, which all wrap their payload in it before enqueueing), so
# whatever masking rules or `mask_hook` the integrator configured, the raw
# `data` still reached stdout as-is.
#
# stdout in any containerised deployment is captured, shipped and retained by
# the host's own logging stack -- a destination the integrator has even less
# control over than the network call this gem also makes. An integrator who
# configured a masking rule and confirmed the value was absent from what
# reaches intake would find it correct, and find the value in their own logs
# anyway. Hence a plain caller-supplied sensitive value below, rather than a
# configured masking rule: masking was never in the picture for this leak,
# and (separately) LogWriter's record type has no masking field map at all
# yet (EndPointBlank::Masking::FIELD_MAP[:log] is empty), so a masking rule
# would silently no-op here regardless -- that gap is tracked by the sibling
# masking-parity story, not this one.
#
# This is the regression test the JS SDK already has for its equivalent
# leak; the Ruby gem had none, which is how the `puts` survived a coverage
# push to ~98% -- the *other* LogWriter spec stubs `puts` away (to keep test
# output quiet) without ever asserting on what would have been printed.
RSpec.describe EndPointBlank::Writers::LogWriter do
  let(:writer) { described_class.instance }

  # Real delivery is irrelevant to this leak; stub the enqueue boundary so
  # the example never touches the background send threads or the network.
  before { allow(writer).to receive(:enqueue) }

  after { EndPointBlank::Rack::EnvStore.clear }

  def capture_stdout
    out = StringIO.new
    original_stdout = $stdout
    begin
      $stdout = out
      yield
    ensure
      $stdout = original_stdout
    end
    out.string
  end

  it "never prints the caller's log data to stdout" do
    sensitive = "ssn:078-05-1120"

    captured = capture_stdout { described_class.info("user updated", ssn: sensitive) }

    expect(captured).not_to include(sensitive)
  end

  it "never prints the caller's log message to stdout" do
    sensitive_message = "password reset token abc123 issued"

    captured = capture_stdout { described_class.info(sensitive_message) }

    expect(captured).not_to include(sensitive_message)
  end

  it "writes nothing to stdout at all on an ordinary write" do
    captured = capture_stdout { described_class.info("user updated", ssn: "078-05-1120") }

    expect(captured).to be_empty
  end
end
