# frozen_string_literal: true

require "spec_helper"

RSpec.describe "EndPointBlank::Middleware::Rack::ReportInteraction when the request fails" do
  let(:env) { ::Rack::MockRequest.env_for("/things") }
  let(:responses) { [] }

  before do
    allow(EndPointBlank::Writers::RequestWriter).to receive(:write)
    allow(EndPointBlank::Writers::ExceptionWriter).to receive(:write)
    allow(EndPointBlank::Writers::ResponseWriter).to receive(:write) { |args| responses << args }
  end

  after { EndPointBlank::Rack::EnvStore.clear }

  def middleware_raising(error)
    EndPointBlank::Middleware::Rack::ReportInteraction.new(->(_env) { raise error })
  end

  describe "a rejected caller" do
    let(:unauthorized) { EndPointBlank::UnauthorizedError.new("Authorization failed") }

    it "still records the response, so the refusal is auditable" do
      expect { middleware_raising(unauthorized).call(env) }.to raise_error(EndPointBlank::UnauthorizedError)

      expect(responses.last[:status]).to eq(401)
    end

    it "records the status the error carries" do
      expect { middleware_raising(EndPointBlank::UnauthorizedError.new("nope", 403)).call(env) }
        .to raise_error(EndPointBlank::UnauthorizedError)

      expect(responses.last[:status]).to eq(403)
    end

    # A caller without credentials is the system working, not an incident. It
    # would otherwise page the provider on every unauthenticated probe.
    it "is not reported as an application error" do
      expect { middleware_raising(unauthorized).call(env) }.to raise_error(EndPointBlank::UnauthorizedError)

      expect(EndPointBlank::Writers::ExceptionWriter).not_to have_received(:write)
    end

    it "re-raises so the host application still decides what the caller sees" do
      expect { middleware_raising(unauthorized).call(env) }
        .to raise_error(EndPointBlank::UnauthorizedError, "Authorization failed")
    end

    it "clears the per-request state even though the request ended in an error" do
      expect { middleware_raising(unauthorized).call(env) }.to raise_error(EndPointBlank::UnauthorizedError)

      expect(EndPointBlank::Rack::EnvStore.get).to be_nil
    end
  end

  describe "an application error" do
    it "records a 500, since the real status is rendered outside this middleware" do
      expect { middleware_raising(RuntimeError.new("boom")).call(env) }.to raise_error(RuntimeError)

      expect(responses.last[:status]).to eq(500)
    end

    it "reports the exception" do
      expect { middleware_raising(RuntimeError.new("boom")).call(env) }.to raise_error(RuntimeError)

      expect(EndPointBlank::Writers::ExceptionWriter).to have_received(:write)
    end
  end

  describe "reporting the outcome of its own delivery" do
    let(:logger) { double("logger", debug: nil, error: nil) }
    let(:middleware) { EndPointBlank::Middleware::Rack::ReportInteraction.new(->(_env) { [200, {}, ["ok"]] }) }

    before { allow(EndPointBlank).to receive(:logger).and_return(logger) }

    it "logs a successful delivery at debug level, where it stays out of the way" do
      middleware.on_success(double("response", body: "ok"))

      expect(logger).to have_received(:debug).with(/ok/)
    end

    it "logs a failed delivery at error level, where a provider will see it" do
      middleware.on_failure(double("response", body: "rejected"))

      expect(logger).to have_received(:error).with(/rejected/)
    end
  end
end

RSpec.describe EndPointBlank::UnauthorizedError do
  it "defaults to 401" do
    expect(described_class.new("nope").status).to eq(401)
  end

  it "carries a status the caller chose" do
    expect(described_class.new("nope", 403).status).to eq(403)
  end

  it "carries its message like any other error" do
    expect(described_class.new("Authorization failed").message).to eq("Authorization failed")
  end
end
