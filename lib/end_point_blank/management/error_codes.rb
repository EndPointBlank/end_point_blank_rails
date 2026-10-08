# frozen_string_literal: true

module EndPointBlank
  module Management
    # Every +error.code+ the management API can answer, with its HTTP status, as
    # app_portal's docs list them, plus the few codes this SDK raises itself
    # when there is no API answer to read one from.
    #
    # Match on these rather than on messages, which are for people and may
    # change. The list is not closed: an {Error} carrying a code missing here
    # still raises with that code, so a newer API never breaks an older SDK.
    module ErrorCodes
      # Authentication and limits
      MISSING_KEY = "missing_key"
      INVALID_KEY = "invalid_key"
      RUNTIME_CREDENTIAL_REFUSED = "runtime_credential_refused"
      INSUFFICIENT_SCOPE = "insufficient_scope"
      AUDIT_UNAVAILABLE = "audit_unavailable"
      RATE_LIMITED = "rate_limited"
      PLAN_LIMIT = "plan_limit"

      # Requests
      VALIDATION_FAILED = "validation_failed"
      # No such resource in your organization (another organization's id
      # answers this too), or no such /api/v1 path.
      NOT_FOUND = "not_found"
      INVALID_PAGINATION = "invalid_pagination"
      INVALID_FILTER = "invalid_filter"
      INVALID_IDEMPOTENCY_KEY = "invalid_idempotency_key"
      IDEMPOTENCY_KEY_REUSED = "idempotency_key_reused"
      IDEMPOTENCY_REQUEST_IN_PROGRESS = "idempotency_request_in_progress"
      IDEMPOTENCY_REPLAY_UNAVAILABLE = "idempotency_replay_unavailable"
      # Any request the API cannot read (e.g. a body that is not JSON).
      BAD_REQUEST = "bad_request"
      INTERNAL_SERVER_ERROR = "internal_server_error"

      # Applications, environments and API packages
      HAS_DEPENDENTS = "has_dependents"
      PROTECTED = "protected"
      INVALID_ENVIRONMENT_BASE_URLS = "invalid_environment_base_urls"
      API_PACKAGE_ASSIGNED = "api_package_assigned"
      INTAKE_SYNC_FAILED = "intake_sync_failed"

      # Credentials
      DELETE_REFUSED = "delete_refused"
      INTAKE_CREDENTIAL = "intake_credential"
      INTAKE_REJECTED = "intake_rejected"
      INTAKE_UNAVAILABLE = "intake_unavailable"

      # Clients, packages and grants
      INVALID_CONTACTS = "invalid_contacts"
      INVALID_PACKAGES = "invalid_packages"
      INVALID_GRANTS = "invalid_grants"
      INVALID_MANAGED = "invalid_managed"
      CLIENT_NOT_ACCEPTED = "client_not_accepted"
      CLIENT_ACCEPTED = "client_accepted"
      CLIENT_NOT_MANAGED = "client_not_managed"
      ALREADY_A_MEMBER = "already_a_member"
      ALREADY_INVITED = "already_invited"
      INVITE_ACCEPTED = "invite_accepted"
      INVITE_NOT_OPEN = "invite_not_open"
      INVITE_RATE_LIMITED = "invite_rate_limited"
      NOT_AN_EMAIL_INVITE = "not_an_email_invite"
      CLIENT_BEING_REMOVED = "client_being_removed"
      CLIENT_NOT_REMOVABLE = "client_not_removable"
      MANAGED_CLIENT_HAS_CREDENTIALS = "managed_client_has_credentials"
      API_PACKAGE_NOT_FOUND = "api_package_not_found"
      ENVIRONMENT_NOT_FOUND = "environment_not_found"
      ALREADY_ASSIGNED = "already_assigned"
      NOTHING_PUBLISHED_IN_ENVIRONMENT = "nothing_published_in_environment"
      APPLICATION_NOT_FOUND = "application_not_found"
      ENDPOINT_NOT_FOUND = "endpoint_not_found"
      ENVIRONMENT_NOT_IN_APPLICATION = "environment_not_in_application"
      ALREADY_GRANTED = "already_granted"
      GRANT_REVOKED_CONCURRENTLY = "grant_revoked_concurrently"
      # A claim invite's +return_to+ is not one of the claim return URLs your
      # organization registered.
      RETURN_TO_NOT_REGISTERED = "return_to_not_registered"
      # A portal session's +return_url+ is not one of those claim return URLs.
      RETURN_URL_NOT_REGISTERED = "return_url_not_registered"
      # A portal session for a managed client with no owner email; set one
      # with <tt>clients.update</tt>.
      OWNER_EMAIL_MISSING = "owner_email_missing"

      # The warning code API package endpoint writes answer in +warnings+ (not
      # an error): a client assignment of the package now derives no grant.
      ASSIGNMENT_DERIVES_NOTHING = "assignment_derives_nothing"

      # Raised by this SDK, never sent by the API: the request never got an
      # answer (DNS, TLS, refused connection, timeout).
      CONNECTION_ERROR = "connection_error"
      # Raised by this SDK: an error answer whose body is not the API's JSON
      # error shape, such as an HTML page from a proxy. +status+ still says
      # what happened.
      HTTP_ERROR = "http_error"
      # Raised by this SDK: a success answer whose body is not JSON.
      INVALID_RESPONSE = "invalid_response"

      # The HTTP status the API answers each of its codes with.
      STATUSES = {
        MISSING_KEY => 401, INVALID_KEY => 401, RUNTIME_CREDENTIAL_REFUSED => 401,
        INSUFFICIENT_SCOPE => 403, AUDIT_UNAVAILABLE => 503, RATE_LIMITED => 429, PLAN_LIMIT => 402,
        VALIDATION_FAILED => 422, NOT_FOUND => 404, INVALID_PAGINATION => 400, INVALID_FILTER => 422,
        INVALID_IDEMPOTENCY_KEY => 400, IDEMPOTENCY_KEY_REUSED => 422,
        IDEMPOTENCY_REQUEST_IN_PROGRESS => 409, IDEMPOTENCY_REPLAY_UNAVAILABLE => 409,
        BAD_REQUEST => 400, INTERNAL_SERVER_ERROR => 500,
        HAS_DEPENDENTS => 422, PROTECTED => 422, INVALID_ENVIRONMENT_BASE_URLS => 422,
        API_PACKAGE_ASSIGNED => 422, INTAKE_SYNC_FAILED => 422,
        DELETE_REFUSED => 422, INTAKE_CREDENTIAL => 409, INTAKE_REJECTED => 422, INTAKE_UNAVAILABLE => 503,
        INVALID_CONTACTS => 422, INVALID_PACKAGES => 422, INVALID_GRANTS => 422, INVALID_MANAGED => 422,
        CLIENT_NOT_ACCEPTED => 422, CLIENT_ACCEPTED => 422, CLIENT_NOT_MANAGED => 422,
        ALREADY_A_MEMBER => 422, ALREADY_INVITED => 409, INVITE_ACCEPTED => 422, INVITE_NOT_OPEN => 422,
        INVITE_RATE_LIMITED => 429, NOT_AN_EMAIL_INVITE => 422, CLIENT_BEING_REMOVED => 422,
        CLIENT_NOT_REMOVABLE => 422, MANAGED_CLIENT_HAS_CREDENTIALS => 422, API_PACKAGE_NOT_FOUND => 422,
        ENVIRONMENT_NOT_FOUND => 422, ALREADY_ASSIGNED => 422, NOTHING_PUBLISHED_IN_ENVIRONMENT => 422,
        APPLICATION_NOT_FOUND => 422, ENDPOINT_NOT_FOUND => 422, ENVIRONMENT_NOT_IN_APPLICATION => 422,
        ALREADY_GRANTED => 422, GRANT_REVOKED_CONCURRENTLY => 409, RETURN_TO_NOT_REGISTERED => 422,
        RETURN_URL_NOT_REGISTERED => 422, OWNER_EMAIL_MISSING => 422
      }.freeze

      # Every code the API can send, as strings.
      ALL = STATUSES.keys.freeze

      # Codes this SDK raises itself.
      SDK = [CONNECTION_ERROR, HTTP_ERROR, INVALID_RESPONSE].freeze

      # Whether +code+ is one this version of the SDK knows about.
      def self.known?(code)
        STATUSES.key?(code) || SDK.include?(code)
      end
    end
  end
end
