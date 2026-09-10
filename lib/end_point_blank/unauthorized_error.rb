# frozen_string_literal: true

require "json"

module EndPointBlank
  # Raised when a request fails authentication or authorization.
  #
  # This error is intentionally not logged by the middleware, as unauthorized
  # access attempts are expected to occur.
  #
  # `status` carries the status intake answered the authenticate or authorize
  # call with, so a handler can tell the two refusals apart: 401 means the
  # credential was not accepted and the integrator should check it, 403 means
  # the credential was fine but no grant covers this endpoint and the
  # integrator should ask for one. Collapsing both to 401 sends them to debug
  # the wrong thing. The other SDKs each carry the same value under their own
  # idiomatic name -- `statusCode` in JS, `getStatusCode()` in Java,
  # `status_code` in Python; this is Ruby's.
  #
  # It defaults to 401 so that `UnauthorizedError.new(message)` keeps working
  # unchanged, and because 401 is the safe reading of a refusal that arrives
  # with no status attached. The concerns never lean on that default: they pass
  # intake's status, or 503 when intake did not answer at all.
  class UnauthorizedError < StandardError
    attr_reader :status

    def initialize(message = nil, status = 401)
      super(message)
      @status = status
    end

    # Builds the error for a non-201 answer to intake's authenticate or
    # authorize call. `action` is "Authentication" or "Authorization".
    #
    # One method rather than a copy per concern. `Rails::Authenticated` and
    # `Rails::Authorized` were two transcriptions of one decision, and two
    # copies is how one path acquires a fix the other does not. That is not
    # hypothetical here: `authorize!` passed intake's status and read the body
    # defensively, while `authenticate!` used `raise UnauthorizedError,
    # "message"` -- the two-argument `raise Class, message` form, which
    # structurally cannot pass a status however willing this class is to accept
    # one -- and parsed the body before it had checked there was a body to
    # parse. Both are fixed here, once.
    #
    # @param result [#status, #body, nil] intake's answer, or nil if it did not
    #   answer at all.
    # @param action [String] the word naming what was attempted.
    # @return [UnauthorizedError]
    def self.refusal_from(result, action)
      if result.nil?
        # Intake never answered at all, so nothing refused this caller and 401
        # would blame a credential that was never judged. 503 says the true
        # thing -- the check could not be made -- and is what the other four
        # SDKs already send for this same case: JS and Java
        # `response ? response.status : 503`, Python's `refusal_from`, and
        # Elixir's literal `send_resp(503, ...)`. It is also the one case the
        # "service unavailable" wording is actually true for.
        #
        # The wording deliberately has no "#{action} failed:" prefix, because
        # that is what `authorize!` has always sent for this case and this
        # method must not change what the working path produces for any input.
        # The other SDKs prefix it; the status, which is what a handler
        # branches on, agrees with them.
        return new("#{action} service unavailable", 503)
      end

      # Intake's verdict verbatim. 401 tells an integrator to check the
      # credential, 403 tells them to ask for a grant.
      new("#{action} failed: #{reason_from(result)}", result.status)
    end

    # intake sends `{"error": "..."}`, but the SDK reaches it through a proxy
    # and a WAF or load balancer can answer with an HTML page intake never
    # generated. An unparseable body is therefore an expected case, not a
    # swallowed failure: it falls back to the raw body so the operator still
    # sees exactly what came back rather than an empty reason.
    def self.reason_from(result)
      parsed =
        begin
          JSON.parse(result.body)
        rescue StandardError
          nil
        end

      detail = parsed.is_a?(Hash) ? parsed["error"] : nil
      detail || result.body
    end
    private_class_method :reason_from
  end
end
