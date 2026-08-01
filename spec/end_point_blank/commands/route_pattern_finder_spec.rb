# frozen_string_literal: true

require "spec_helper"

RSpec.describe EndPointBlank::Commands::RoutePatternFinder do
  let(:request) { double("request") }

  def application_matching(*patterns)
    router = double("router")
    allow(router).to receive(:recognize) do |_request, &block|
      patterns.each { |pattern| block.call(double("route", path: double("path", spec: pattern)), {}) }
    end
    double("application", routes: double("routes", router: router))
  end

  it "reports the route pattern the request matched, not the concrete path" do
    # Intake groups responses by route, so /widgets/1 and /widgets/2 have to
    # arrive as the same endpoint.
    with_fake_rails(application: application_matching("/widgets/:id(.:format)")) do
      expect(described_class.find(request)).to eq("/widgets/:id(.:format)")
    end
  end

  it "takes the first match when a request matches more than one route" do
    with_fake_rails(application: application_matching("/widgets/:id", "/:anything")) do
      expect(described_class.find(request)).to eq("/widgets/:id")
    end
  end

  it "returns nil when the request matches no route" do
    with_fake_rails(application: application_matching) do
      expect(described_class.find(request)).to be_nil
    end
  end

  # This runs on every response. A routing lookup that blows up must cost the
  # caller a nil, not their response.
  it "returns nil rather than raising when the routing lookup fails" do
    logger = double("logger", debug: nil)
    allow(EndPointBlank).to receive(:logger).and_return(logger)
    router = double("router")
    allow(router).to receive(:recognize).and_raise(RuntimeError, "routes not loaded")
    application = double("application", routes: double("routes", router: router))

    with_fake_rails(application: application) do
      result = nil
      expect { result = described_class.find(request) }.not_to raise_error
      expect(result).to be_nil
    end

    expect(logger).to have_received(:debug).with(/routes not loaded/)
  end
end
