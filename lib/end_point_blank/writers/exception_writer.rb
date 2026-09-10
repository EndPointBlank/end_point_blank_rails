# frozen_string_literal: true

require "singleton"

module EndPointBlank
  module Writers
    class ExceptionWriter
      include Singleton
      include DelayedWriter
      include Shared

      attr_reader :url

      def initialize
        super()
        @url = EndPointBlank::Configuration.instance.errors_url
        start_threads
      end

      def self.write(exception)
        instance.write(exception)
      end

      # Builds an error payload with or without an in-flight request. `env` is
      # nil whenever an exception is reported from outside `EnvStore`'s scope
      # (a background job, a worker, a boot-time failure) -- that is precisely
      # the case this method exists to handle, not an edge case to special-case
      # away. `Rack::Request.new(env)` was built unconditionally here even
      # though nothing about an error report requires a request: version
      # detection (Commands::VersionFinder) reads request params/path and is
      # meaningless without one, so it is skipped rather than attempted and
      # rescued. Its result was never even merged into the returned hash, so
      # skipping it changes nothing for the in-request case either.
      def payload(exception)
        env = ::EndPointBlank::Rack::EnvStore.get
        {
          app_name: app_name,
          uuid: request_uuid(env),
          message: exception.message,
          stacktrace: exception.backtrace,
          sent_at: Time.now.utc.iso8601(3),
          source_application_environment_id: source_application_environment_id
        }
      end

      def write(exception)
        p = payload(exception)
        rack_req = ::EndPointBlank::Rack::EnvStore.request
        if rack_req
          p = p.merge(
            stamped_path: rack_req.path,
            stamped_http_method: rack_req.request_method
          )
        end
        enqueue(apply_masking(p, :error))
      end
    end
  end
end
