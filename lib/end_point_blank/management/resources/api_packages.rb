# frozen_string_literal: true

require_relative "base"

module EndPointBlank
  module Management
    module Resources
      # +/api_packages+: your organization's API packages, and what each one
      # publishes (+/api_packages/:id/endpoints+).
      #
      # A package: <tt>{"id", "name", "organization_id", "inserted_at",
      # "updated_at"}</tt>.
      class ApiPackages < Base
        # GET /api_packages. @return [Page]
        def list(limit: nil, after: nil)
          list_page(path("api_packages"), limit, after)
        end

        # Every API package, across pages. @return [Enumerator, nil]
        def each(limit: nil, &block)
          each_item(path("api_packages"), limit, &block)
        end

        # GET /api_packages/:id. @return [Hash]
        def get(id)
          get_data(path("api_packages", id))
        end

        # POST /api_packages. @return [Hash] the new package
        def create(name:, idempotency_key: nil)
          post_data(path("api_packages"), { name: name }, idempotency_key)
        end

        # PATCH /api_packages/:id (rename). @return [Hash]
        def update(id, name:)
          patch_data(path("api_packages", id), { name: name })
        end

        # DELETE /api_packages/:id. Refused with +api_package_assigned+ while
        # a client holds it. @return [Hash] <tt>{"id", "deleted"}</tt>
        def delete(id)
          delete_data(path("api_packages", id))
        end

        # GET /api_packages/:id/endpoints: what the package publishes, one
        # entry per application endpoint (or whole application) and
        # environment. An entry: <tt>{"id", "api_package_id",
        # "application_id", "endpoint_id", "all_endpoints", "endpoint",
        # "environment_id", "inserted_at"}</tt>. @return [Page]
        def list_endpoints(api_package_id, limit: nil, after: nil)
          list_page(path("api_packages", api_package_id, "endpoints"), limit, after)
        end

        # Every entry of the package, across pages. @return [Enumerator, nil]
        def each_endpoint(api_package_id, limit: nil, &block)
          each_item(path("api_packages", api_package_id, "endpoints"), limit, &block)
        end

        # POST /api_packages/:id/endpoints. Leave +endpoint_id+ nil to publish
        # every endpoint of the application.
        #
        # Answers the whole body, not only +data+: <tt>{"data" => entry,
        # "warnings" => [...]}</tt>. Each warning (code
        # +assignment_derives_nothing+) names a client assignment of the
        # package that derives no grant.
        #
        # @return [Hash] <tt>{"data", "warnings"}</tt>
        def add_endpoint(api_package_id, application_id:, environment_id:, endpoint_id: nil, idempotency_key: nil)
          body = compact(application_id: application_id, endpoint_id: endpoint_id, environment_id: environment_id)
          @transport.request("POST", path("api_packages", api_package_id, "endpoints"),
                             body: body, idempotency_key: idempotency_key)
        end

        # DELETE /api_packages/:id/endpoints/:access_id. Answers the whole
        # body, as {#add_endpoint} does.
        #
        # @return [Hash] <tt>{"data" => {"id", "deleted"}, "warnings" => [...]}</tt>
        def remove_endpoint(api_package_id, access_id)
          @transport.request("DELETE", path("api_packages", api_package_id, "endpoints", access_id))
        end
      end

      # +GET /endpoints+: the endpoints of your organization's applications,
      # to find the ids {ApiPackages#add_endpoint} takes.
      #
      # An endpoint: <tt>{"id", "application_id", "path", "action", "public",
      # "inserted_at", "updated_at"}</tt>.
      class Endpoints < Base
        # @param application_id [String, nil] only this application's endpoints
        # @param version [String, nil] only endpoints deployed in an
        #   application version of this name
        # @return [Page]
        def list(application_id: nil, version: nil, limit: nil, after: nil)
          list_page(path("endpoints"), limit, after, application_id: application_id, version: version)
        end

        # Every matching endpoint, across pages. @return [Enumerator, nil]
        def each(application_id: nil, version: nil, limit: nil, &block)
          each_item(path("endpoints"), limit, { application_id: application_id, version: version }, &block)
        end
      end
    end
  end
end
