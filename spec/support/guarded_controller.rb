# frozen_string_literal: true

# A stand-in for the Rails controller that `Rails::Authenticated` and
# `Rails::Authorized` install their `before_action` into.
#
# It provides the two things the concerns actually touch -- a class-level
# `before_action` and an instance-level `request` -- and records the former, so
# a spec can assert the guard really was installed rather than only that the
# method exists. Everything else about ActionController is irrelevant to what
# these concerns decide.
module GuardedController
  # @param concern [Module] EndPointBlank::Rails::Authenticated or ::Authorized
  # @return [Class] a fresh class including it
  def guarded_controller_class(concern)
    Class.new do
      # Defined before the include, because the concern's `included do` block
      # calls `before_action` the moment it is included.
      def self.before_actions
        @before_actions ||= []
      end

      def self.before_action(name)
        before_actions << name
      end

      include concern

      attr_reader :request

      def initialize(request)
        @request = request
      end
    end
  end

  # Shaped like the ActionDispatch request the concerns hand to the commands:
  # `headers`, `request_method`, `route_uri_pattern`, `remote_ip`, `uuid`,
  # `path`, `params` and `env` are between them everything BasicAuthenticate,
  # EndpointAuthorize and VersionFinder read.
  def guarded_request(auth: "Bearer client-token", method: "GET", pattern: "/widgets(.:format)",
                      host: "api.example.test", ip: "203.0.113.7", uuid: "req-1",
                      path: "/widgets", version: "v1")
    double(
      "request",
      headers: { "Authorization" => auth },
      request_method: method,
      route_uri_pattern: pattern,
      host: host,
      remote_ip: ip,
      uuid: uuid,
      path: path,
      params: { "version" => version },
      env: { "HTTP_HOST" => host }
    )
  end

  # intake's answer, or nil for "intake did not answer at all".
  def intake_answer(status, body)
    double("response", status: status, body: body)
  end
end
