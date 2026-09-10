# frozen_string_literal: true

require "spec_helper"

# `refusal_from` is the single decision both Rails guards make about a non-201
# answer from intake. It exists because there were two copies of it and only one
# of them was right.
#
# Honesty about what these prove: every example below fails against the
# pre-change code, but only because the method did not exist there -- they are
# NoMethodError, not a wrong answer. What they pin is the contract the two
# concerns now rely on. The examples that show the old behaviour was wrong are
# in `rails/authenticated_spec.rb` and `rails/refusal_parity_spec.rb`, and the
# ones marked GUARD below pass for `authorize!` against master too, because that
# path already answered this way and must keep answering this way.
RSpec.describe EndPointBlank::UnauthorizedError do
  def answer(status, body)
    double("response", status: status, body: body)
  end

  describe "the status it carries" do
    it "defaults to 401 when constructed with a message alone" do
      # GUARD. The class has always accepted a status; that was never the gap.
      # The gap was that `authenticate!` used `raise Class, message`, which
      # cannot pass one. This pins the default the two-argument construction
      # documented in the README still relies on.
      error = described_class.new("no credentials")

      expect(error.status).to eq(401)
      expect(error.message).to eq("no credentials")
    end

    it "is the one it was given" do
      # GUARD, same reason.
      expect(described_class.new("not entitled", 403).status).to eq(403)
    end
  end

  describe ".refusal_from, when intake refused the caller" do
    it "keeps the status intake decided on" do
      expect(described_class.refusal_from(answer(403, '{"error":"access_denied"}'), "Authentication").status)
        .to eq(403)
    end

    it "uses the reason intake gave" do
      expect(described_class.refusal_from(answer(403, '{"error":"access_denied"}'), "Authentication").message)
        .to eq("Authentication failed: access_denied")
    end

    it "names the action it was performing" do
      expect(described_class.refusal_from(answer(403, '{"error":"access_denied"}'), "Authorization").message)
        .to eq("Authorization failed: access_denied")
    end

    it "keeps a rejected credential's 401 as a 401" do
      expect(described_class.refusal_from(answer(401, '{"error":"invalid_client"}'), "Authentication").status)
        .to eq(401)
    end
  end

  describe ".refusal_from, when intake itself failed" do
    it "surfaces the 5xx rather than reporting it as a refusal" do
      # A 500 from intake is not a statement about this caller. Reporting it as
      # 401 sends the integrator to re-issue a credential that is fine, and
      # hides an outage behind a credential problem.
      expect(described_class.refusal_from(answer(500, "boom"), "Authentication").status).to eq(500)
    end
  end

  describe ".refusal_from, when intake did not answer at all" do
    it "says 503, because nothing judged this caller" do
      expect(described_class.refusal_from(nil, "Authentication").status).to eq(503)
    end

    it "says so in the message" do
      # No "...failed:" prefix, matching what `authorize!` has always sent for
      # this case. The prefix is the one place this gem's wording differs from
      # the JS, Java and Python ports; the status, which is what a handler
      # branches on, agrees with all three.
      expect(described_class.refusal_from(nil, "Authorization").message)
        .to eq("Authorization service unavailable")
    end
  end

  describe ".refusal_from, reading the body" do
    it "falls back to the raw text when the body is not JSON" do
      # A proxy in front of intake answers with an HTML or plain-text error
      # page. The operator still needs to see what came back.
      refusal = described_class.refusal_from(answer(502, "Bad Gateway"), "Authentication")

      expect(refusal.message).to eq("Authentication failed: Bad Gateway")
      expect(refusal.status).to eq(502)
    end

    it "falls back to the raw text for JSON carrying no error key" do
      expect(described_class.refusal_from(answer(422, '{"detail":"nope"}'), "Authorization").message)
        .to eq('Authorization failed: {"detail":"nope"}')
    end

    it "still carries the status when the body is nil" do
      # Excon hands back a body of "" rather than nil, but a CachedResponse or
      # a hand-rolled double need not, and losing the status because the reason
      # could not be read is the failure this whole method exists to remove.
      expect(described_class.refusal_from(answer(500, nil), "Authorization").status).to eq(500)
    end

    it "does not treat a JSON array body as a hash" do
      expect(described_class.refusal_from(answer(400, "[1,2]"), "Authentication").message)
        .to eq("Authentication failed: [1,2]")
    end
  end
end
