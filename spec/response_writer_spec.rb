# frozen_string_literal: true

require "spec_helper"

# ResponseWriter#payload sends `route` (the matched endpoint pattern) so the
# intake service can associate a response with a specific route. Spy health
# checks additionally need the request's HTTP method to disambiguate routes
# that respond to more than one verb (e.g. GET /widgets/:id vs DELETE
# /widgets/:id), so `method` must travel alongside `route` in the same
# payload, and mirror its nil-safety when there is no in-flight request.
RSpec.describe EndPointBlank::Writers::ResponseWriter do
  describe "#payload" do
    context "when a request is present" do
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
      after { EndPointBlank::Rack::EnvStore.clear }

      it "includes the request's HTTP method alongside route" do
        payload = described_class.instance.payload(status: 200, headers: {}, body: "ok")

        expect(payload[:method]).to eq("GET")
      end
    end

    context "when there is no request" do
      before do
        # Stub at the EnvStore.request boundary (rather than clearing the
        # whole EnvStore) so this isolates the request-nil branch of
        # ResponseWriter#payload; EnvStore.get must still return a Rack env
        # hash, since Headers.extract reads from it directly and is
        # unrelated to this task.
        allow(EndPointBlank::Rack::EnvStore).to receive(:request).and_return(nil)
        allow(EndPointBlank::Rack::EnvStore).to receive(:get).and_return({})
      end

      it "sets method to nil, mirroring route's nil-safety" do
        payload = described_class.instance.payload(status: 200, headers: {}, body: "ok")

        expect(payload[:route]).to be_nil
        expect(payload[:method]).to be_nil
      end
    end
  end
end
