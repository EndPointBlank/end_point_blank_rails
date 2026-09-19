# frozen_string_literal: true

require "spec_helper"

CONFIGURATION_SPEC_ENV_KEYS = %w[
  ENDPOINTBLANK_CLIENT_ID
  ENDPOINTBLANK_CLIENT_SECRET
  ENDPOINTBLANK_BASE_URL
  ENDPOINTBLANK_LOG_BASE_URL
  ENDPOINTBLANK_APP_NAME
  ENDPOINTBLANK_ENV
].freeze

CONFIGURATION_SPEC_IVARS = %i[@client_id @client_secret @base_url @log_base_url @app_name @env_name].freeze

# rubocop:disable Metrics/BlockLength
RSpec.describe EndPointBlank::Configuration do
  let(:configuration) { described_class.instance }

  around do |example|
    original_env = CONFIGURATION_SPEC_ENV_KEYS.each_with_object({}) { |k, h| h[k] = ENV.delete(k) }
    original_ivars = CONFIGURATION_SPEC_IVARS.each_with_object({}) do |k, h|
      h[k] = configuration.instance_variable_get(k)
    end

    example.run

    CONFIGURATION_SPEC_IVARS.each { |k| configuration.instance_variable_set(k, original_ivars[k]) }
    CONFIGURATION_SPEC_ENV_KEYS.each { |k| ENV.delete(k) }
    original_env.each { |k, v| ENV[k] = v unless v.nil? }
  end

  before do
    CONFIGURATION_SPEC_IVARS.each { |k| configuration.instance_variable_set(k, nil) }
  end

  describe "#client_id" do
    it "falls back to ENDPOINTBLANK_CLIENT_ID when unset" do
      ENV["ENDPOINTBLANK_CLIENT_ID"] = "env-client-id"

      expect(configuration.client_id).to eq("env-client-id")
    end

    it "prefers an explicitly configured value over the env var" do
      ENV["ENDPOINTBLANK_CLIENT_ID"] = "env-client-id"
      EndPointBlank.configure { |c| c.client_id = "explicit-client-id" }

      expect(configuration.client_id).to eq("explicit-client-id")
    end

    it "returns nil when neither is set" do
      expect(configuration.client_id).to be_nil
    end
  end

  describe "#client_secret" do
    it "falls back to ENDPOINTBLANK_CLIENT_SECRET when unset" do
      ENV["ENDPOINTBLANK_CLIENT_SECRET"] = "env-client-secret"

      expect(configuration.client_secret).to eq("env-client-secret")
    end

    it "prefers an explicitly configured value over the env var" do
      ENV["ENDPOINTBLANK_CLIENT_SECRET"] = "env-client-secret"
      EndPointBlank.configure { |c| c.client_secret = "explicit-client-secret" }

      expect(configuration.client_secret).to eq("explicit-client-secret")
    end

    it "returns nil when neither is set" do
      expect(configuration.client_secret).to be_nil
    end
  end

  describe "#base_url" do
    it "falls back to ENDPOINTBLANK_BASE_URL when unset" do
      ENV["ENDPOINTBLANK_BASE_URL"] = "https://env.example.com"

      expect(configuration.base_url).to eq("https://env.example.com")
    end

    it "prefers an explicitly configured value over the env var" do
      ENV["ENDPOINTBLANK_BASE_URL"] = "https://env.example.com"
      EndPointBlank.configure { |c| c.base_url = "https://explicit.example.com" }

      expect(configuration.base_url).to eq("https://explicit.example.com")
    end

    it "defaults to https://in.endpointblank.com when neither is set" do
      expect(configuration.base_url).to eq("https://in.endpointblank.com")
    end
  end

  describe "#log_base_url" do
    it "falls back to ENDPOINTBLANK_LOG_BASE_URL when unset" do
      ENV["ENDPOINTBLANK_LOG_BASE_URL"] = "https://env-log.example.com"

      expect(configuration.log_base_url).to eq("https://env-log.example.com")
    end

    it "prefers an explicitly configured value over the env var" do
      ENV["ENDPOINTBLANK_LOG_BASE_URL"] = "https://env-log.example.com"
      EndPointBlank.configure { |c| c.log_base_url = "https://explicit-log.example.com" }

      expect(configuration.log_base_url).to eq("https://explicit-log.example.com")
    end

    it "defaults to https://log.endpointblank.com when neither is set" do
      expect(configuration.log_base_url).to eq("https://log.endpointblank.com")
    end
  end

  describe "#app_name" do
    it "falls back to ENDPOINTBLANK_APP_NAME when unset and ::Rails is undefined" do
      expect(defined?(::Rails)).to be_falsey
      ENV["ENDPOINTBLANK_APP_NAME"] = "env-app-name"

      expect(configuration.app_name).to eq("env-app-name")
    end

    it "prefers an explicitly configured value over the env var" do
      ENV["ENDPOINTBLANK_APP_NAME"] = "env-app-name"
      EndPointBlank.configure { |c| c.app_name = "explicit-app-name" }

      expect(configuration.app_name).to eq("explicit-app-name")
    end

    it "returns nil without raising when unset and ::Rails is undefined" do
      expect(defined?(::Rails)).to be_falsey

      expect { configuration.app_name }.not_to raise_error
      expect(configuration.app_name).to be_nil
    end

    it "derives a name from the Rails application when nothing else is set" do
      with_fake_rails(application: double("application", name: "MyApp::Application")) do
        expect(configuration.app_name).to include("my_app")
      end
    end

    it "still prefers the env var over the Rails application name" do
      ENV["ENDPOINTBLANK_APP_NAME"] = "env-app-name"

      with_fake_rails(application: double("application", name: "MyApp::Application")) do
        expect(configuration.app_name).to eq("env-app-name")
      end
    end
  end

  describe "#env_name" do
    it "falls back to ENDPOINTBLANK_ENV when unset" do
      ENV["ENDPOINTBLANK_ENV"] = "env-name-from-env"

      expect(configuration.env_name).to eq("env-name-from-env")
    end

    it "prefers an explicitly configured value over the env var" do
      ENV["ENDPOINTBLANK_ENV"] = "env-name-from-env"
      EndPointBlank.configure { |c| c.env_name = "explicit-env-name" }

      expect(configuration.env_name).to eq("explicit-env-name")
    end

    it "returns nil when neither is set" do
      expect(configuration.env_name).to be_nil
    end
  end

  # sc-970 sets one rule for all five SDKs. Omitting cache_ttl means the 300s
  # default; 0 disables the cache; an explicit nil, a negative number, or a
  # non-Integer is a configuration error raised by the assignment itself --
  # at configure time, during boot -- not at the first cache read or store.
  #
  # Deliberately not added to CONFIGURATION_SPEC_IVARS: the `before` above
  # nils every ivar in that list, and nil is exactly the value this setting
  # must never hold. Snapshot and restore it through the ivar instead, so
  # restoring never goes through the writer under test.
  describe "#cache_ttl" do
    around do |example|
      original_cache_ttl = configuration.instance_variable_get(:@cache_ttl)
      example.run
      configuration.instance_variable_set(:@cache_ttl, original_cache_ttl)
    end

    it "defaults to 300 seconds when never set" do
      # A fresh instance, not the shared singleton: other specs assign
      # cache_ttl, so "never set" is only honest on an object nothing touched.
      expect(described_class.send(:new).cache_ttl).to eq(300)
    end

    it "accepts a positive Integer" do
      EndPointBlank.configure { |c| c.cache_ttl = 60 }

      expect(configuration.cache_ttl).to eq(60)
    end

    # What 0 *does* (disables the cache) is pinned where it happens, in
    # spec/end_point_blank/commands/authentication_cache_spec.rb.
    it "accepts 0" do
      EndPointBlank.configure { |c| c.cache_ttl = 0 }

      expect(configuration.cache_ttl).to eq(0)
    end

    it "raises at the assignment itself on an explicit nil, naming cache_ttl and saying to omit it for the default" do
      expect { EndPointBlank.configure { |c| c.cache_ttl = nil } }
        .to raise_error(ArgumentError) { |error|
          expect(error.message).to include("cache_ttl")
          expect(error.message).to include("got nil")
          expect(error.message).to include("To use the default of 300 seconds, omit the cache_ttl setting")
          expect(error.message).to include("0 to disable")
        }
    end

    {
      "a negative Integer" => -5,
      "-1, which used to mean disabled" => -1,
      "a String" => "abc",
      "a numeric String" => "300",
      "a Float" => 3.5,
      "a whole-number Float" => 300.0,
      "a Rational" => Rational(300, 1),
      "a boolean" => true
    }.each do |description, value|
      it "raises at the assignment itself on #{description} (#{value.inspect}), naming cache_ttl and the value" do
        expect { EndPointBlank.configure { |c| c.cache_ttl = value } }
          .to raise_error(ArgumentError) { |error|
            expect(error.message).to include("cache_ttl")
            expect(error.message).to include("got #{value.inspect}")
            expect(error.message).to include("To use the default of 300 seconds, omit the cache_ttl setting")
          }
      end
    end

    it "leaves the previous value in place when an assignment is rejected" do
      EndPointBlank.configure { |c| c.cache_ttl = 120 }

      [nil, -5, "abc", 3.5].each do |value|
        expect { configuration.cache_ttl = value }.to raise_error(ArgumentError)
        expect(configuration.cache_ttl).to eq(120)
      end
    end
  end

  # sc-1266: the sc-970 reviews found that this SDK's configure block applied
  # each assignment to the live singleton as the block executed, so a field
  # set before an invalid one stuck even though the whole call raised. This
  # pins the fix as all-or-nothing: nothing a rejected `configure` call
  # touched may differ from before the call, proven here by mutating a field
  # that has no validation of its own (app_name) alongside one that does
  # (cache_ttl).
  describe ".configure" do
    around do |example|
      original_cache_ttl = configuration.instance_variable_get(:@cache_ttl)
      # Captured with #dup up front, not just the reference: the bug this
      # spec's masking_rules example pins is exactly an in-place mutation of
      # the live array, so restoring the same (already-mutated) object after
      # the example would be a no-op and would leak the mutation into every
      # test that runs after it.
      original_masking_rules = configuration.instance_variable_get(:@masking_rules).map(&:dup)
      example.run
      configuration.instance_variable_set(:@cache_ttl, original_cache_ttl)
      configuration.instance_variable_set(:@masking_rules, original_masking_rules)
    end

    it "does not apply a valid field when a later field in the same call is invalid" do
      configuration.app_name = "original-app-name"

      expect do
        EndPointBlank.configure do |c|
          c.app_name = "new-app-name"
          c.cache_ttl = -1
        end
      end.to raise_error(ArgumentError)

      expect(configuration.app_name).to eq("original-app-name")
    end

    it "does not apply any of several valid fields set before the invalid one that raises" do
      configuration.app_name = "original-app-name"
      configuration.client_id = "original-client-id"

      expect do
        EndPointBlank.configure do |c|
          c.app_name = "new-app-name"
          c.client_id = "new-client-id"
          c.cache_ttl = -1
        end
      end.to raise_error(ArgumentError)

      expect(configuration.app_name).to eq("original-app-name")
      expect(configuration.client_id).to eq("original-client-id")
    end

    # senior-dev review of PR #40 (finding 1): the file-level `before` above
    # nils every CONFIGURATION_SPEC_IVARS entry before each example, so
    # every test above starts from ivars that already exist. That hides the
    # one case that actually differs: a field a `configure` block sets for
    # the very first time, before anything else has ever assigned it (a
    # fresh boot). This test undoes that fixture for @client_id specifically
    # so it starts genuinely unset, the way it is in a real process before
    # any configure call.
    it "does not create a field the block sets for the first time when a later field in the same call is invalid" do
      configuration.remove_instance_variable(:@client_id) if configuration.instance_variable_defined?(:@client_id)

      expect do
        EndPointBlank.configure do |c|
          c.client_id = "half-applied"
          c.cache_ttl = -1
        end
      end.to raise_error(ArgumentError)

      expect(configuration.instance_variable_defined?(:@client_id)).to be(false)
      expect(configuration.client_id).to be_nil
    end

    # senior-dev review of PR #40 (finding 2): masking_rules is a mutable
    # Array (see Configuration#initialize and the README's "ordered list of
    # masking rule hashes"), and `<<` mutates it in place rather than
    # replacing it. A rollback that only restores ivar *references* cannot
    # undo that: restoring "the same array" restores nothing.
    it "does not keep an in-block append to masking_rules when a later field in the same call is invalid" do
      configuration.masking_rules = []

      expect do
        EndPointBlank.configure do |c|
          c.masking_rules << { "type" => "probe" }
          c.cache_ttl = -1
        end
      end.to raise_error(ArgumentError)

      expect(configuration.masking_rules).to eq([])
    end

    # senior-dev review of PR #40 (finding 3): the original rollback only
    # rescued StandardError, so a block that raised a ScriptError (LoadError,
    # NotImplementedError) or any other non-StandardError Exception kept
    # whatever it had already applied. NotImplementedError is used here
    # because it needs no environment setup; LoadError from a `require` for
    # a missing optional dependency is a realistic way this happens for real.
    it "does not apply a field set before the block raises an exception that is not a StandardError" do
      configuration.app_name = "original-app-name"

      expect do
        EndPointBlank.configure do |c|
          c.app_name = "new-app-name"
          raise NotImplementedError, "boom"
        end
      end.to raise_error(NotImplementedError)

      expect(configuration.app_name).to eq("original-app-name")
    end

    # java#39 follow-up (sc-1266): copy-then-commit makes a single call
    # atomic, but two overlapping calls both start from the same live state,
    # and without serialization whichever finishes committing last wins --
    # even when it is a call that was always going to fail. At 31dc8dc
    # (rollback-in-place, no lock) this reproduces the java review's finding
    # directly: thread A applies its field straight to the live singleton,
    # pauses, thread B's independent, valid call commits "b-value" to the
    # live singleton while A is paused, and then A's rollback restores A's
    # own stale pre-call snapshot over the top of B's commit. The Mutex
    # closes this by holding the lock across the block *and* the commit, so
    # thread B cannot even start running its own block until thread A's
    # call -- raise included -- has fully released the lock.
    it "does not let a failing configure call on one thread affect a successful concurrent call on another" do
      configuration.app_name = "original-app-name"
      paused = Queue.new
      thread_a_error = nil

      thread_a = Thread.new do
        EndPointBlank.configure do |c|
          c.app_name = "a-value"
          paused << true
          # Long enough that thread B -- an uncontended, near-instant call
          # with no sleep of its own -- is certain to finish first if
          # nothing is serializing the two calls.
          sleep 0.3
          c.cache_ttl = -1
        end
      rescue ArgumentError => e
        thread_a_error = e
      end

      paused.pop
      thread_b = Thread.new { EndPointBlank.configure { |c| c.app_name = "b-value" } }

      thread_a.join
      thread_b.join

      expect(thread_a_error).to be_a(ArgumentError)
      expect(configuration.app_name).to eq("b-value")
    end
  end
end
# rubocop:enable Metrics/BlockLength
