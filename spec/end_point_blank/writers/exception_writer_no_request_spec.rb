# frozen_string_literal: true

require "spec_helper"

# sc-377: ExceptionWriter#payload built a Rack::Request from a possibly-nil
# EnvStore env with no rescue. Outside a request (a background job, a worker,
# a boot-time failure) EnvStore.get is nil, Rack::Request.new(nil) is built
# without error, but the first method that dereferences its env --
# Commands::VersionFinder#find reading request.params / request.path --
# raises NoMethodError from inside the handler that exists to report errors.
#
# Independently, request_uuid(env) read only
# env["action_dispatch.request_id"], which nothing but Rails'
# ActionDispatch::RequestId middleware ever sets, and EnvStore never minted a
# uuid. So even a payload that *did* build successfully carried uuid: nil,
# which intake refuses (validate_required([:uuid, ...]) in
# Intake.Errors.ApplicationError).
# rubocop:disable Metrics/BlockLength
RSpec.describe EndPointBlank::Writers::ExceptionWriter do
  let(:writer) { described_class.instance }
  let(:exception) do
    raise "boom"
  rescue RuntimeError => e
    e
  end

  after { EndPointBlank::Rack::EnvStore.clear }

  describe "with no request context at all (EnvStore empty)" do
    before { EndPointBlank::Rack::EnvStore.clear }

    it "builds a payload instead of raising a second, unrelated exception" do
      expect { writer.payload(exception) }.not_to raise_error
    end

    it "mints a fresh uuid rather than sending a refused nil" do
      payload = writer.payload(exception)

      expect(payload[:uuid]).to be_a(String)
      expect(payload[:uuid]).to match(/\A[0-9a-f-]{36}\z/)
    end

    it "mints a different uuid on each call, i.e. it is not a cached fallback" do
      first = writer.payload(exception)[:uuid]
      second = writer.payload(exception)[:uuid]

      expect(first).not_to eq(second)
    end

    it "still carries the rest of the exception payload" do
      payload = writer.payload(exception)

      expect(payload[:message]).to eq("boom")
      expect(payload[:stacktrace]).to eq(exception.backtrace)
      expect(payload[:app_name]).to eq(EndPointBlank::Configuration.instance.app_name)
    end

    it "does not include a request stamp, since there is no request to stamp" do
      enqueued = nil
      allow(writer).to receive(:enqueue) { |payload| enqueued = payload }

      expect { described_class.write(exception) }.not_to raise_error

      expect(enqueued[:uuid]).to be_a(String)
      expect(enqueued[:message]).to eq("boom")
      expect(enqueued).not_to have_key(:stamped_path)
    end
  end

  describe "with a request context present" do
    let(:env) do
      {
        "action_dispatch.request_id" => "abc-123",
        "REQUEST_METHOD" => "GET",
        "PATH_INFO" => "/x",
        "SERVER_NAME" => "example.test",
        "SERVER_PORT" => "80",
        "rack.input" => StringIO.new("")
      }
    end

    before { EndPointBlank::Rack::EnvStore.set(env) }

    it "uses the existing request id rather than minting a new one" do
      payload = writer.payload(exception)

      expect(payload[:uuid]).to eq("abc-123")
    end

    it "stamps the path and method on write, unchanged behaviour" do
      enqueued = nil
      allow(writer).to receive(:enqueue) { |payload| enqueued = payload }

      described_class.write(exception)

      expect(enqueued[:uuid]).to eq("abc-123")
      expect(enqueued[:stamped_path]).to eq("/x")
      expect(enqueued[:stamped_http_method]).to eq("GET")
    end
  end
end
# rubocop:enable Metrics/BlockLength
