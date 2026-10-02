# frozen_string_literal: true

require_relative "base"

module EndPointBlank
  module Management
    module Resources
      # +/applications+, and each application's environments
      # (+/applications/:application_id/environments+, an "application
      # environment": the application placed in an environment at a base URL).
      #
      # An application: <tt>{"id", "name", "public", "organization_group_id",
      # "synced_at", "inserted_at", "updated_at"}</tt>. An application
      # environment: <tt>{"id", "application_id", "environment_id",
      # "base_url", ...}</tt>.
      class Applications < Base
        # @return [Page]
        def list(limit: nil, after: nil)
          list_page(path("applications"), limit, after)
        end

        # @return [Enumerator, nil]
        def each(limit: nil, &block)
          each_item(path("applications"), limit, &block)
        end

        # @return [Hash]
        def get(id)
          get_data(path("applications", id))
        end

        # POST /applications.
        #
        # @param environment_base_urls [Hash] environment id => base URL; at
        #   least one is required
        # @return [Hash] the new application
        def create(name:, environment_base_urls:, public: nil, organization_group_id: nil, idempotency_key: nil)
          body = compact(name: name, environment_base_urls: environment_base_urls, public: public,
                         organization_group_id: organization_group_id)
          post_data(path("applications"), body, idempotency_key)
        end

        # PATCH /applications/:id. Only the arguments given are sent.
        # @return [Hash]
        def update(id, name: nil, public: nil)
          patch_data(path("applications", id), compact(name: name, public: public))
        end

        # DELETE /applications/:id. Refused with +has_dependents+ while grants
        # or credentials depend on it. @return [Hash] <tt>{"id", "deleted"}</tt>
        def delete(id)
          delete_data(path("applications", id))
        end

        # GET /applications/:application_id/environments. @return [Page]
        def list_environments(application_id, limit: nil, after: nil)
          list_page(path("applications", application_id, "environments"), limit, after)
        end

        # @return [Enumerator, nil]
        def each_environment(application_id, limit: nil, &block)
          each_item(path("applications", application_id, "environments"), limit, &block)
        end

        # POST /applications/:application_id/environments: place the
        # application in an environment at +base_url+.
        # @return [Hash] the application environment
        def add_environment(application_id, environment_id:, base_url:, idempotency_key: nil)
          post_data(path("applications", application_id, "environments"),
                    { environment_id: environment_id, base_url: base_url }, idempotency_key)
        end

        # DELETE /applications/:application_id/environments/:id, where +id+ is
        # the application environment's id. @return [Hash] <tt>{"id", "deleted"}</tt>
        def remove_environment(application_id, id)
          delete_data(path("applications", application_id, "environments", id))
        end
      end

      # +/environments+: deployment environments.
      #
      # An environment: <tt>{"id", "name", "domain", "is_default", ...}</tt>.
      class Environments < Base
        # @return [Page]
        def list(limit: nil, after: nil)
          list_page(path("environments"), limit, after)
        end

        # @return [Enumerator, nil]
        def each(limit: nil, &block)
          each_item(path("environments"), limit, &block)
        end

        # @return [Hash]
        def get(id)
          get_data(path("environments", id))
        end

        # POST /environments. @return [Hash] the new environment
        def create(name:, domain:, is_default: nil, idempotency_key: nil)
          post_data(path("environments"), compact(name: name, domain: domain, is_default: is_default),
                    idempotency_key)
        end

        # PATCH /environments/:id. Only the arguments given are sent. The
        # production environment answers +protected+. @return [Hash]
        def update(id, name: nil, domain: nil, is_default: nil)
          patch_data(path("environments", id), compact(name: name, domain: domain, is_default: is_default))
        end

        # DELETE /environments/:id. @return [Hash] <tt>{"id", "deleted"}</tt>
        def delete(id)
          delete_data(path("environments", id))
        end
      end

      # +/credentials+: runtime client credentials (the client_id and
      # client_secret an SDK authenticates with).
      #
      # A credential: <tt>{"id", "client_id", "secret_last_4",
      # "application_environment_id", "application_id", "environment",
      # "previous_secret", "expired_at", "created_at", "updated_at"}</tt>.
      # {#create} and {#rotate} add +client_secret+, the only time the secret
      # is ever returned: store it then. This SDK never logs it.
      class Credentials < Base
        # @param application_environment_id [String, nil] only this
        #   application environment's credentials
        # @return [Page] metadata only, no secrets
        def list(application_environment_id: nil, limit: nil, after: nil)
          list_page(path("credentials"), limit, after, application_environment_id: application_environment_id)
        end

        # @return [Enumerator, nil]
        def each(application_environment_id: nil, limit: nil, &block)
          each_item(path("credentials"), limit, { application_environment_id: application_environment_id }, &block)
        end

        # @return [Hash] metadata only, no secret
        def get(id)
          get_data(path("credentials", id))
        end

        # POST /credentials. A retry of a create that succeeded but whose
        # answer was lost raises +idempotency_replay_unavailable+: list the
        # application environment's credentials instead.
        # @return [Hash] the credential, with its one-time +client_secret+
        def create(application_environment_id:, idempotency_key: nil)
          post_data(path("credentials"), { application_environment_id: application_environment_id }, idempotency_key)
        end

        # POST /credentials/:id/rotate: a new secret; the old one keeps
        # working for the grace window (see +previous_secret+).
        # @return [Hash] the credential, with its new one-time +client_secret+
        def rotate(id, idempotency_key: nil)
          post_data(path("credentials", id, "rotate"), nil, idempotency_key)
        end

        # DELETE /credentials/:id: revokes the credential on intake, then
        # removes it. @return [Hash] <tt>{"id", "deleted"}</tt>
        def delete(id)
          delete_data(path("credentials", id))
        end
        alias revoke delete
      end
    end
  end
end
