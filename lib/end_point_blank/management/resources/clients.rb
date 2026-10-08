# frozen_string_literal: true

require_relative "base"

module EndPointBlank
  module Management
    module Resources
      # +/clients+: the organizations you serve as their provider, as client
      # invites (pending and accepted), and managed clients you run for your
      # customers.
      #
      # A client: <tt>{"id", "name", "status" ("pending"/"accepted"),
      # "invite_code" (write keys, while pending), "accepted_at", "managed",
      # "claimed_at", "client_organization", "inserted_at", "updated_at"}</tt>;
      # {#get} adds +contacts+ and +pre_assignments+.
      class Clients < Base
        # GET /clients. @return [Page]
        def list(limit: nil, after: nil)
          list_page(path("clients"), limit, after)
        end

        # Every client, across pages. @return [Enumerator, nil]
        def each(limit: nil, &block)
          each_item(path("clients"), limit, &block)
        end

        # GET /clients/:id. @return [Hash]
        def get(id)
          get_data(path("clients", id))
        end

        # POST /clients.
        #
        # @param contacts [Array<Hash>, nil] your contacts to share, each
        #   <tt>{email:, first_name:, last_name:, title: nil, phone_number: nil}</tt>
        # @param packages [Array<Hash>, nil] API packages to assign when the
        #   client accepts, each <tt>{api_package_id:, environment_id:}</tt>
        # @param grants [Array<Hash>, nil] direct grants to make when it
        #   accepts, each <tt>{target_application_id:, environment_id:,
        #   target_endpoint_id: nil}</tt>
        # @param managed [Boolean, nil] true creates a managed client (no
        #   packages or grants with it; assign those afterwards)
        # @param owner_email [String, nil] with <tt>managed: true</tt>, the
        #   email address of the person at your customer who will own the
        #   managed client; change it later with {#update}
        # @return [Hash] the new client; +invite_code+ is what the client
        #   accepts with
        # rubocop:disable Metrics/ParameterLists
        def create(name:, contacts: nil, packages: nil, grants: nil, managed: nil, owner_email: nil,
                   idempotency_key: nil)
          body = compact(name: name, contacts: contacts, packages: packages, grants: grants, managed: managed,
                         owner_email: owner_email)
          post_data(path("clients"), body, idempotency_key)
        end
        # rubocop:enable Metrics/ParameterLists

        # Invites a client: {#create} without +managed+.
        def invite(name:, contacts: nil, packages: nil, grants: nil, idempotency_key: nil)
          create(name: name, contacts: contacts, packages: packages, grants: grants,
                 idempotency_key: idempotency_key)
        end

        # Creates a managed client: {#create} with <tt>managed: true</tt>. Set
        # it up with {Client#for_managed_client}.
        def create_managed(name:, contacts: nil, owner_email: nil, idempotency_key: nil)
          create(name: name, contacts: contacts, managed: true, owner_email: owner_email,
                 idempotency_key: idempotency_key)
        end

        # PATCH /clients/:id: +owner_email+ is the email address of the
        # person at your customer who will own a managed client. @return [Hash]
        def update(id, owner_email:)
          patch_data(path("clients", id), { owner_email: owner_email })
        end

        # DELETE /clients/:id. Refused with +managed_client_has_credentials+
        # for a managed client that still holds credentials.
        # @return [Hash] <tt>{"id", "deleted"}</tt>
        def delete(id)
          delete_data(path("clients", id))
        end

        # POST /clients/:client_id/claim_invites: emails your customer an
        # invite to claim a managed client.
        #
        # +return_to+ (optional, sent only when given) is where EndPointBlank
        # sends the customer's browser once they have claimed it. It must
        # equal, byte for byte, a claim return URL your organization
        # registered in EndPointBlank, or the call is refused with
        # +return_to_not_registered+ (422).
        # @return [Hash] <tt>{"client_id", "email", "sent_at", "expires_at"}</tt>
        def claim_invite(client_id, email:, return_to: nil, idempotency_key: nil)
          body = { email: email }
          body[:return_to] = return_to unless return_to.nil?
          post_data(path("clients", client_id, "claim_invites"), body, idempotency_key)
        end

        # POST /clients/:client_id/portal_sessions: mints a single-use link
        # that signs the owner of managed client +client_id+ in to its
        # EndPointBlank portal.
        #
        # The link expires 60 seconds after it is minted and works once, so
        # mint it when the user clicks and redirect their browser to it; never
        # render it into a page, log it or send it in an email. +return_url+
        # (optional, sent only when given) is where the portal links back to,
        # and must equal, byte for byte, a claim return URL your organization
        # registered.
        #
        # Each call sends a new Idempotency-Key unless you pass one, and that
        # is what you want: the answer is never replayed, so a key used before
        # is refused with +idempotency_replay_unavailable+ (409). Never reuse a
        # key across clicks.
        #
        # Refused with +not_found+ (404) for a client that is not yours, and
        # with +client_not_managed+ (not a managed client, or already
        # claimed), +client_being_removed+, +owner_email_missing+ (set one with
        # {#update}) or +return_url_not_registered+ (an empty string included),
        # all 422.
        # @return [Hash] <tt>{"client_id", "url", "expires_at", "return_url"}</tt>,
        #   +return_url+ nil when none was given
        def create_portal_session(client_id, return_url: nil, idempotency_key: nil)
          body = return_url.nil? ? nil : { return_url: return_url }
          post_data(path("clients", client_id, "portal_sessions"), body, idempotency_key)
        end
      end

      # +/clients/:client_id/packages+: the API packages a client holds from
      # you, or (on a pending invite) is set up to get when it accepts.
      #
      # An assignment: <tt>{"id", "api_package_id", "api_package_name",
      # "environment_id", "status" ("active"/"pending"/"refused"), "refusal",
      # "inserted_at", "updated_at"}</tt>.
      class PackageAssignments < Base
        # @return [Page]
        def list(client_id, limit: nil, after: nil)
          list_page(path("clients", client_id, "packages"), limit, after)
        end

        # @return [Enumerator, nil]
        def each(client_id, limit: nil, &block)
          each_item(path("clients", client_id, "packages"), limit, &block)
        end

        # POST /clients/:client_id/packages. Refused with e.g.
        # +nothing_published_in_environment+ or +already_assigned+.
        # @return [Hash] the assignment
        def create(client_id, api_package_id:, environment_id:, idempotency_key: nil)
          post_data(path("clients", client_id, "packages"),
                    { api_package_id: api_package_id, environment_id: environment_id }, idempotency_key)
        end
        alias assign create

        # PATCH /clients/:client_id/packages/:id: move the assignment to
        # another environment. @return [Hash]
        def update(client_id, id, environment_id:)
          patch_data(path("clients", client_id, "packages", id), { environment_id: environment_id })
        end

        # DELETE /clients/:client_id/packages/:id. @return [Hash] <tt>{"id", "deleted"}</tt>
        def delete(client_id, id)
          delete_data(path("clients", client_id, "packages", id))
        end
        alias unassign delete
      end

      # +/clients/:client_id/grants+: the grants a client holds directly from
      # you (package-derived grants are managed through {PackageAssignments}).
      #
      # A grant: <tt>{"id", "client_organization_id", "target_application_id",
      # "target_endpoint_id", "all_endpoints", "environment_id",
      # "also_granted_by_api_package_ids", "synced_at", "status", "refusal",
      # "inserted_at", "updated_at"}</tt>.
      class Grants < Base
        # @return [Page]
        def list(client_id, limit: nil, after: nil)
          list_page(path("clients", client_id, "grants"), limit, after)
        end

        # @return [Enumerator, nil]
        def each(client_id, limit: nil, &block)
          each_item(path("clients", client_id, "grants"), limit, &block)
        end

        # POST /clients/:client_id/grants. Leave +target_endpoint_id+ nil to
        # grant every endpoint of the application. @return [Hash] the grant
        def create(client_id, target_application_id:, environment_id:, target_endpoint_id: nil, idempotency_key: nil)
          body = compact(target_application_id: target_application_id, target_endpoint_id: target_endpoint_id,
                         environment_id: environment_id)
          post_data(path("clients", client_id, "grants"), body, idempotency_key)
        end

        # DELETE /clients/:client_id/grants/:id. @return [Hash] <tt>{"id", "deleted"}</tt>
        def delete(client_id, id)
          delete_data(path("clients", client_id, "grants", id))
        end
        alias revoke delete
      end
    end
  end
end
