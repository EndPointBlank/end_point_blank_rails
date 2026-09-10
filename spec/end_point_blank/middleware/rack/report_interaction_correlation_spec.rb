# frozen_string_literal: true

require "spec_helper"

# sc-377: `request_uuid(env)` used to be a pure function. `RequestWriter` and
# `ResponseWriter` both call it with the *same* env object for one HTTP
# request -- EnvStore hands back whatever `set/1` was given at the top of the
# middleware, unchanged, for the life of the request -- so under Rails,
# `action_dispatch.request_id` being set once was enough to keep both writers'
# rows correlated.
#
# Under plain Rack (no Rails, no `action_dispatch.request_id`), nothing kept
# them correlated: each writer independently minted its own uuid, so the
# request row and the response row for a single interaction carried two
# different, unrelated ids. Both rows existed and neither was refused, so
# nothing failed loudly -- an interaction just silently stopped being
# joinable, on every request, for the life of the process.
RSpec.describe EndPointBlank::Middleware::Rack::ReportInteraction do
  let(:middleware) { described_class.new(->(_env) { [200, {}, ["{}"]] }) }

  # Deliberately no "action_dispatch.request_id" -- this is the plain Rack /
  # Sinatra shape the bug lived in.
  let(:env) { ::Rack::MockRequest.env_for("/things") }

  after { EndPointBlank::Rack::EnvStore.clear }

  it "gives RequestWriter and ResponseWriter the same minted uuid for one request" do
    sent = []
    allow(EndPointBlank::Writers::RequestWriter).to receive(:write) do
      sent << EndPointBlank::Writers::RequestWriter.instance.send(:payload)[:uuid]
    end
    allow(EndPointBlank::Writers::ResponseWriter).to receive(:write) do |**kwargs|
      sent << EndPointBlank::Writers::ResponseWriter.instance.send(:payload, **kwargs)[:uuid]
    end

    middleware.call(env)

    expect(sent.length).to eq(2)
    expect(sent[0]).not_to be_nil
    expect(sent[0]).to eq(sent[1])
  end

  it "gives two separate requests two different uuids" do
    # The fix must not go too far the other way and make every request share
    # one id -- EnvStore.set/1 replaces the env wholesale each time, so a
    # fresh request must mint its own.
    first_uuid = nil
    second_uuid = nil

    allow(EndPointBlank::Writers::RequestWriter).to receive(:write) do
      first_uuid ||= EndPointBlank::Writers::RequestWriter.instance.send(:payload)[:uuid]
    end
    allow(EndPointBlank::Writers::ResponseWriter).to receive(:write)

    middleware.call(env)
    EndPointBlank::Rack::EnvStore.clear

    allow(EndPointBlank::Writers::RequestWriter).to receive(:write) do
      second_uuid = EndPointBlank::Writers::RequestWriter.instance.send(:payload)[:uuid]
    end

    middleware.call(::Rack::MockRequest.env_for("/other"))

    expect(second_uuid).not_to eq(first_uuid)
  end
end
