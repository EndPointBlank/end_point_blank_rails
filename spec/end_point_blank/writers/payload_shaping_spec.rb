# frozen_string_literal: true

require "spec_helper"

RSpec.describe EndPointBlank::Writers::ResponseWriter do
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

  def body_recorded_for(body)
    described_class.instance.payload(status: 200, headers: {}, body: body)[:body]
  end

  describe "recording the response body" do
    # A Rack body is an enumerable of chunks, not a string; recording it
    # without joining would store "#<Rack::BodyProxy...>" instead of the
    # response the caller actually received.
    it "joins the chunks of a Rack body" do
      expect(body_recorded_for(['{"a": 1}'])).to eq('{"a": 1}')
    end

    it "joins a multi-chunk Rack body in order" do
      expect(body_recorded_for(%w[one two three])).to eq("onetwothree")
    end

    it "reads the body off a response object that carries one" do
      expect(body_recorded_for(double("response", body: "from response object"))).to eq("from response object")
    end

    it "records nothing for a response with no body" do
      expect(body_recorded_for(nil)).to be_nil
    end

    it "stringifies anything else" do
      expect(body_recorded_for(:ok)).to eq("ok")
    end

    it "truncates a large body and marks it, so one response cannot dominate the payload" do
      recorded = body_recorded_for(["x" * 5000])

      expect(recorded.length).to eq(1027)
      expect(recorded).to end_with("...")
    end

    it "leaves a body at the limit untouched" do
      expect(body_recorded_for(["x" * 1024])).to eq("x" * 1024)
    end
  end
end

RSpec.describe EndPointBlank::Writers::LogWriter do
  let(:writer) { described_class.instance }
  let(:enqueued) { [] }

  before do
    allow(writer).to receive(:enqueue) { |payload| enqueued << payload }
    allow(writer).to receive(:puts)
  end

  it "records a message at info level" do
    described_class.info("hello")

    expect(enqueued.last).to include(message: "hello", log_level: :info)
  end

  it "records a message at warn level" do
    described_class.warn("careful")

    expect(enqueued.last).to include(message: "careful", log_level: :warn)
  end

  it "records a message at error level" do
    described_class.error("broken")

    expect(enqueued.last).to include(message: "broken", log_level: :error)
  end

  it "records a message at fatal level" do
    described_class.fatal("dead")

    expect(enqueued.last).to include(message: "dead", log_level: :fatal)
  end

  it "carries the caller's structured data alongside the message" do
    described_class.info("hello", order_id: 7)

    expect(enqueued.last[:data]).to eq(order_id: 7)
  end

  it "accepts an arbitrary level through .write" do
    described_class.write("hello", :debug)

    expect(enqueued.last[:log_level]).to eq(:debug)
  end

  describe "stamping the in-flight request" do
    # Log lines are the one payload that can be written outside a request, so
    # the request stamp has to be added only when there is one to add.
    after { EndPointBlank::Rack::EnvStore.clear }

    it "stamps the path and method of the request being served" do
      EndPointBlank::Rack::EnvStore.set(::Rack::MockRequest.env_for("/orders", method: "POST"))

      described_class.info("hello")

      expect(enqueued.last).to include(stamped_path: "/orders", stamped_http_method: "POST")
    end

    it "omits the stamp outside a request" do
      EndPointBlank::Rack::EnvStore.clear

      described_class.info("hello")

      expect(enqueued.last).not_to have_key(:stamped_path)
    end
  end
end

RSpec.describe EndPointBlank::Writers::DirectWriter do
  let(:configuration) { EndPointBlank::Configuration.instance }

  around do |example|
    original = %i[@client_id @client_secret].each_with_object({}) do |ivar, memo|
      memo[ivar] = configuration.instance_variable_get(ivar)
    end

    example.run

    original.each { |ivar, value| configuration.instance_variable_set(ivar, value) }
  end

  before do
    configuration.client_id = "cid"
    configuration.client_secret = "csecret"
  end

  it "posts the batch to its URL, wrapped under a payload key" do
    allow(EndPointBlank::Commands::Http).to receive(:post).and_return(double("response", status: 200))

    described_class.new("https://intake.example.test/api/logs").write([{ id: 1 }, { id: 2 }])

    expect(EndPointBlank::Commands::Http).to have_received(:post).with(
      "https://intake.example.test/api/logs",
      start_with("Basic "),
      { payload: [{ id: 1 }, { id: 2 }] }
    )
  end
end

RSpec.describe EndPointBlank::Writers::Shared do
  after { EndPointBlank::Rack::EnvStore.clear }

  it "reads the in-flight Rack env" do
    env = ::Rack::MockRequest.env_for("/things")
    EndPointBlank::Rack::EnvStore.set(env)

    expect(EndPointBlank::Writers::RequestWriter.instance.env).to equal(env)
  end

  it "reads nothing outside a request" do
    EndPointBlank::Rack::EnvStore.clear

    expect(EndPointBlank::Writers::RequestWriter.instance.env).to be_nil
  end
end
