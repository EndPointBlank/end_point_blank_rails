# EndPointBlank (Ruby)

The Ruby client for [EndPointBlank](https://endpointblank.com): API endpoint tracking, endpoint
authorization, error/request/response/log reporting, and client-side data masking — with a
**framework-agnostic core** that runs in plain Ruby or Sinatra, plus a Rails adapter that
auto-loads (railtie + middleware) when Rails is present.

## Capabilities

- **Endpoint tracking** — every request/response passing through the Rack middleware is reported.
- **Authorization** — outbound calls to other EndPointBlank-protected services carry a
  `Bearer` access token (never this service's own client credentials), and inbound requests can be authorized
  against the EndPointBlank service before your action runs.
- **Error, request, response, and log reporting** — background, queued, non-blocking delivery to
  the EndPointBlank intake API.
- **Client-side data masking** (`EndPointBlank::Masking` / `masking_rules`) — strip or redact
  sensitive fields from payloads *before* they leave your process, as defense in depth on top of
  server-side masking.
- **Management API client** (`EndPointBlank::Management::Client`) — manage API packages, clients,
  grants, applications, environments, credentials and managed clients from code. See
  [Management API](#management-api).
- **Framework-agnostic core** — `EndPointBlank::Middleware::Rack::ReportInteraction` and the
  writers work directly against Rack env/`::Rack::Request`, so the gem behaves correctly under
  plain Ruby, Sinatra, or any Rack app. When `::Rails` is defined, a `Railtie` auto-inserts the
  middleware and wires up `Rails.logger`; nothing extra needs loading.

## Installation

This gem is **not yet published on RubyGems.org**. Until it is, install it from git.

Add to your `Gemfile`:

```ruby
gem "end_point_blank", github: "EndPointBlank/end_point_blank_rails"
```

(Once released to RubyGems, this collapses to `gem "end_point_blank"`.)

Then:

```sh
bundle install
```

## Quick start

```ruby
EndPointBlank.configure do |config|
  config.client_id     = "your-client-id"
  config.client_secret  = "your-client-secret"
  config.app_name      = "my-service"
end
```

That's it for a Rails app — the railtie auto-inserts the reporting middleware, and every request
processed by your app is tracked. For plain Ruby / Sinatra, see
[Framework integration](#framework-integration) below to wire up the Rack middleware yourself.

To send your first log line:

```ruby
EndPointBlank::Writers::LogWriter.info("service started", { pid: Process.pid })
```

## Configuration

`EndPointBlank.configure { |c| ... }` yields the `EndPointBlank::Configuration` settings and
applies every assignment made inside the block together, only once the block returns without
raising -- a block that raises leaves the configuration exactly as it was before the call.
Every setting listed below can be set explicitly in that block, and most also fall back to an
`ENDPOINTBLANK_*` environment variable, then to a built-in default.

`c` is only valid for the duration of the block: once `configure` returns, whether the block
returned normally or raised, `c` is frozen, and every String, Array or Hash value it holds is
first replaced with its own frozen deep copy. A write made through a reference to `c` kept past
the block always raises `FrozenError` -- a reassignment (`saved.app_name = "x"`) because `c`
itself is frozen, and an in-place edit (`saved.masking_rules << rule`, `saved.app_name << "x"`,
editing a rule Hash in place) because the value it points to is frozen too, not just `c`. A read
that bypasses `c` -- `EndPointBlank::Configuration.instance.app_name`, or `EndPointBlank.logger`
right after `c.logger = ...` earlier in the same block -- still sees the value from before the
`configure` call started, not what the block has set on `c` so far, until the block returns and
the change is applied.

Assigning a String, Array or Hash through `c` copies it rather than storing the object itself:
after `c.masking_rules = rules`, mutating the `rules` array you passed in no longer affects the
live configuration -- call `configure` again to apply a further change. `logger`, `mask_hook`
and `version_finder` are not String/Array/Hash, so they are held by reference like any other
object the caller hands in: mutating one through a retained `c` (`saved.logger.level = ...`)
still reaches the live value, the same as mutating it through `EndPointBlank.logger` or
`Configuration.instance.logger` directly would.

**Precedence: explicit `configure` value > `ENDPOINTBLANK_*` environment variable > default.**

| `configure` setting | Env var fallback | Default | Notes |
|---|---|---|---|
| `client_id` | `ENDPOINTBLANK_CLIENT_ID` | `nil` | Authenticates this service to its own intake (`Basic`). Never sent to a provider. |
| `client_secret` | `ENDPOINTBLANK_CLIENT_SECRET` | `nil` | Paired with `client_id`. |
| `base_url` | `ENDPOINTBLANK_BASE_URL` | `https://in.endpointblank.com` | Base for access-token, authorize, and endpoint-update APIs. |
| `log_base_url` | `ENDPOINTBLANK_LOG_BASE_URL` | `https://log.endpointblank.com` | Base for error/request/response/log reporting APIs. |
| `app_name` | `ENDPOINTBLANK_APP_NAME` | `Rails.application.name.underscore` if Rails is defined, else `nil` | Identifies your app to EndPointBlank. |
| `env_name` | `ENDPOINTBLANK_ENV` | `RACK_ENV`, then `APP_ENV`, then `Rails.env` if defined, else `"production"` (resolved per-request by `SessionConfiguration.env_name`, not read directly off `Configuration`) | The environment name reported with each request/response payload. |
| `logger` | — | A `::Logger.new($stdout, level: ::Logger::INFO)`, or `Rails.logger` under Rails (set by the railtie) | Any object with `.debug`/`.info`/`.warn`/`.error`/`.fatal` works. |
| `worker_count` | — | `4` | Number of background threads draining the delayed writer's queue. Falls back to 2 when set to `nil`. |
| `token_ttl` | — | `nil` | Optional TTL (seconds) requested when generating a `Bearer` access token. |
| `cache_ttl` | — | `300` | TTL, in whole seconds, for the authorization decision cache. **Omit it to get the 300-second default.** `0` disables the cache; any positive `Integer` is that many seconds. Anything else — an explicit `nil`, a negative number, or a non-`Integer` such as `"300"` or `3.5` — raises `ArgumentError` from the `c.cache_ttl = ...` assignment itself, at configure time, and leaves the previous value in place, so a bad value stops your app at boot instead of surfacing on the first authorized request. The cache is a plain in-memory Hash scoped to this process (no `Rails.cache`, Redis, or other shared store), so a Puma or Unicorn worker and every separate app instance each hold their own cache and their own view of `cache_ttl`. Changing `cache_ttl` at runtime takes effect immediately for already-cached entries, not just new ones: an entry is valid only while it is within *both* its original write-time expiry and the *currently configured* `cache_ttl` measured from when it was written, so raising `cache_ttl` never extends an entry already in the cache, and lowering it shortens one on its next read. `cache_ttl = 0` disables the cache — the moment a read or a store in a given process observes it disabled, *that process's* entire cache is cleared, not just the entry being looked up or written, and a store made while disabled inserts nothing there. This is per process, not fleet-wide: each worker or instance clears only its own cache, and only once it has itself observed `cache_ttl` disabled and then handled an `Authorized` request (or a direct cache call) while disabled — a worker that is idle, or hasn't yet picked up the new config, keeps serving whatever it already cached until it does. (A disable followed by a re-enable with no cache read or store in between flushes nothing, since nothing observed the disabled state.) |
| `trust_proxy_headers` | — | `true` | Whether the per-request `scheme`/`host`/`port` report honors `X-Forwarded-Proto`/`-Host`/`-Port`. See [Reported base URL](#reported-base-url). |
| `masking_rules` | — | `[]` | Ordered list of masking rule hashes — see [Data masking](#data-masking). |
| `mask_hook` | — | `nil` | Optional `->(payload, record_type_string) { payload }` run after `masking_rules`. |
| `version_finder` | — | `nil` | Optional `->(request) { "1" }` overriding `EndPointBlank::Commands::VersionFinder`'s default header/param/path detection. |
| `application_version` | — | `nil` | Reserved for reporting your app's own version. |
| `derive_base_url_from_client_id` | — | `false` | Derive the intake hostname from a slug-prefixed `client_id` when no `base_url` is set. See [Intake hostname from `client_id`](#intake-hostname-from-client_id). Only `true` or `false`; anything else raises `ArgumentError` at configure time. |

Note: there is also a bare `environment` accessor on `Configuration`, but it is not read by any
code path in this gem (the real per-request environment name is `env_name`, described above) — do
not rely on it.

### Reported base URL

Every request payload carries the base URL the *caller* used, as three separate fields —
`scheme`, `host` and `port`. A field that cannot be resolved is omitted rather than sent as
null. EndPointBlank uses these to fill in an application environment's base URL for you,
instead of asking someone to type it.

By default the gem honors `X-Forwarded-Proto`, `X-Forwarded-Host` and `X-Forwarded-Port`,
reading the **last** comma-separated hop. It does this on its own, without consulting Rails'
or Rack's trusted-proxy configuration, so that all five EndPointBlank clients answer
identically for the same request.

**Turn this off if your application is reachable directly, with no proxy in front of it** —
or if you would simply rather report nothing than report something a caller could influence:

```ruby
EndPointBlank.configure { |c| c.trust_proxy_headers = false }
```

With it off, the `X-Forwarded-*` headers are ignored entirely and `scheme`, `host` and `port`
come from the connection and the `Host` header only.

It defaults to `true` because the alternative is worse for almost everyone. Most production
deployments sit behind an ALB, nginx, Caddy or an Ingress, and a client that ignored the
forwarded headers there would not report *nothing* — it would confidently report an internal
hostname on an internal port. `host` is caller-controlled either way (it has always come from
the `Host` header), and none of these three values is ever used as an identity or
authorization key, so the worst case is a wrong *suggestion* that an admin has to approve.

### Intake hostname from `client_id`

Each organization's intake will answer at its own hostname,
`https://<slug>.in.endpointblank.com`, and every new `client_id` starts with
that slug and a dot (`acima-x7k2mq.ijXI+MVwmrC5xH/9ZuGiQlAbAyobTqMa`). With
`c.derive_base_url_from_client_id = true`, the gem picks its intake in this
order:

1. `base_url`, or else `ENDPOINTBLANK_BASE_URL`, if either is set;
2. else, if the `client_id` carries a slug prefix,
   `https://<slug>.in.endpointblank.com`;
3. else `https://in.endpointblank.com`.

A `client_id` carries a slug prefix only when the part before its first `.`
has the exact shape of an organization slug and something follows the dot
(`EndPointBlank::Configuration.client_id_slug`). A credential issued before
slugs, including one with a `.` in it such as `my.client`, keeps calling
`https://in.endpointblank.com`.

**This is off by default, and turns on by default in a later release, once
DNS and TLS for `*.in.endpointblank.com` are live.** Until then those
hostnames do not resolve in production, so leave it off unless EndPointBlank
has told you otherwise. With it off, the base URL is `base_url`, else
`ENDPOINTBLANK_BASE_URL`, else `https://in.endpointblank.com`, whatever the
`client_id`.

The logs hostname is not derived: `log_base_url`, else
`ENDPOINTBLANK_LOG_BASE_URL`, else `https://log.endpointblank.com`, as before.

Every call to intake also sends `x-epb-sdk: ruby/<version>`, so
EndPointBlank can tell which SDK versions use a credential before it moves an
organization to another intake. The minimum Ruby version for a move is the
release that turns `derive_base_url_from_client_id` on by default, **not**
this one: with the option at its default here, the gem keeps calling
`https://in.endpointblank.com` after its organization has moved.

### `configure` block example

```ruby
EndPointBlank.configure do |config|
  config.client_id      = "abc123"
  config.client_secret  = "s3cr3t"
  config.base_url       = "https://in.endpointblank.com"
  config.log_base_url   = "https://log.endpointblank.com"
  config.app_name       = "checkout-service"
  config.env_name       = "staging"
  config.logger         = Logger.new($stdout)
end
```

### 12-factor / env-var example

With no `configure` block at all (or a partial one), the same values can come entirely from the
environment:

```sh
export ENDPOINTBLANK_CLIENT_ID=abc123
export ENDPOINTBLANK_CLIENT_SECRET=s3cr3t
export ENDPOINTBLANK_BASE_URL=https://in.endpointblank.com
export ENDPOINTBLANK_LOG_BASE_URL=https://log.endpointblank.com
export ENDPOINTBLANK_APP_NAME=checkout-service
export ENDPOINTBLANK_ENV=staging
```

## Usage

### Authorization

`EndPointBlank::Authorization.header(base_url)` builds the `Authorization` header for an outbound
call to a provider. It is always a `Bearer` token covering `base_url` (via
`EndPointBlank::AccessTokens`, minting one if none is cached). It **never** falls back to `Basic`:
a client must never send its own `client_id` / `client_secret` to a provider or to the provider's
intake. When no token can be obtained it raises `EndPointBlank::TokenUnavailableError` instead.

```ruby
# Pass the URL you are about to call, NOT a hostname. Its userinfo, query and
# fragment are removed before the token request; they are never sent to
# intake, logged, or kept on the error.
url = "https://api.example.com/orders"

begin
  auth = EndPointBlank::Authorization.header(url) # => "Bearer ..."
  Excon.post(url, headers: { "Authorization" => auth }, body: payload)
rescue EndPointBlank::TokenUnavailableError => e
  # No token, so the provider was never called. e.outcome / e.status /
  # e.failure say why (see "Why a token could not be minted" below): retry,
  # degrade, or fail your own request -- but do not send credentials instead.
  Rails.logger.warn(e.message)
  raise
end
```

`base_url` is required. Until this release `header` with no argument returned `Basic` credentials; that
form is gone, and `header(nil)` or `header("")` raises `ArgumentError`, as does a URL that cannot be
parsed into an http or https URL with a host (nothing is sent, and the message does not repeat the URL). The SDK's own calls to its
own intake (authorize, token minting, endpoint updates, the log/request/response writers) still
authenticate with `Basic`, which is safe because intake already holds this service's credential;
they use the internal `EndPointBlank::Authorization.intake_header`, which is not for outbound
calls.

`TokenUnavailableError` (a subclass of `EndPointBlank::Error`) carries `base_url` (the URL with its
userinfo, query and fragment removed; the raw value is never kept), `failure` (the
`EndPointBlank::AccessTokens::Failure` recorded for the mint, or `nil`), and the shortcuts
`outcome` and `status`. Its message names the stripped URL and a fixed reason for the outcome
-- never intake's response body, which stays on `failure.reason` -- for example:

```
Could not mint an EndPointBlank access token for https://api.example.com/orders:
intake rejected this application's client credential (HTTP 401); retrying cannot help --
re-issue the credential. EndPointBlank never sends this service's client_id/client_secret to a
provider, so there is no Basic-auth fallback and the call must not be made without a token.
```

| `outcome` | Reason in the message |
|---|---|
| `:credential_rejected` | `intake rejected this application's client credential (HTTP 401); retrying cannot help -- re-issue the credential` |
| `:request_rejected` | `intake refused the token request (HTTP <status>); check the URL and that a grant covers the target` |
| `:server_error` | `intake failed to issue a token (HTTP <status>); this may be transient` |
| `:transport_error` | `intake could not be reached (timeout, connection refused or retries exhausted); this may be transient` |
| `:transport_error`, the mint raised | `the token request failed unexpectedly` |
| none recorded | `the token request failed for an unknown reason` |

` (HTTP <status>)` is left out when there is no status.

A mint that raises rather than reporting a failure -- a bug, not intake being unreachable -- is
reported as this error too, with outcome `:transport_error`, `unexpected?` true and the exception
as `cause`; its message is not copied into the error's. Only a missing credential's
`ConfigurationError` escapes `header` as itself.

The SDK's own calls to its intake raise `EndPointBlank::ConfigurationError` (also a subclass of
`EndPointBlank::Error`) when `client_id` or `client_secret` is missing or empty, rather than
sending an empty `Basic` credential.

The argument is the URL you are about to call. intake matches it against registered base URLs by
longest path prefix, so you need not know how the target registered itself -- `header` for
`https://api.example.com/orders/42` reuses a token already cached for
`https://api.example.com/orders`. `EndPointBlank::AccessTokens` caches one token per base URL
intake resolves to, not one per process, so a service that calls several targets holds a token
for each. The lookup uses the URL with its userinfo, query and fragment removed and its scheme and
host lowercased, as intake does; beyond that, a URL that does not match character-for-character
(a different path case, an unregistered path) simply misses and mints a new token -- it never guesses.

### Why a token could not be minted

`EndPointBlank::AccessTokens.token` answers with a token String or `nil` (or raises, as itself,
anything the mint raised that is not a transport error -- only `Authorization.header` wraps that),
which is all most callers need. When `nil` is not enough — when you want to know whether retrying could possibly
help — call `token_result` instead, which answers with the token or the `Failure` for that call:

```ruby
url = "https://api.example.com/orders"
result = EndPointBlank::AccessTokens.token_result(url)

if result.is_a?(EndPointBlank::AccessTokens::Failure)
  failure = result

  case failure.outcome
  when :credential_rejected
    # intake answered 401. Permanent until the credential itself changes:
    # re-issue it in the portal and update client_id / client_secret.
    raise "EndPointBlank credential rejected (#{failure.reason})"
  when :request_rejected
    # A 400 or 422: intake could not resolve the target or source
    # application, or the request itself was malformed. Retrying will not fix
    # it, but the credential is fine.
  when :server_error, :transport_error
    # A 5xx, an unusable response, a timeout, a refused connection. Try again.
  end
end
```

`EndPointBlank::AccessTokens.last_failure(url)` still answers the last failure recorded for a
URL, and returns `nil` once a mint for that URL succeeds again, so it never reports a problem
that has already cleared. It is a shared slot, though: read after `token` returned `nil`, another
thread may already have cleared or replaced it. When you need the reason for your own call, use
`token_result`, whose `Failure` is captured inside the cache's lock for that call. A `Failure` carries `base_url`, `outcome`, `status` (the HTTP
status, or `nil` when no usable one was obtained), `reason`, and `at`, and answers
`#credential_rejected?`, `#request_rejected?`, `#server_error?` and `#transport_error?`.

`token`, `token_result`, `exists?` and `last_failure` all remove the URL's userinfo, query and
fragment first, so the cache, the failure record (and its `base_url`) and the log lines only ever
hold the stripped URL. A URL that cannot be parsed into an http or https URL with a host is never sent:
`token_result` answers a `:request_rejected` `Failure` with no `status` and no `base_url`, and
nothing is recorded.

There is deliberately no `#retriable?` or other single retry/no-retry boolean. Retrying a `400`
or a `422` is exactly as futile as retrying a `401` — intake answers `400` for an invalid
`token_ttl` or a missing `base_url`, and `422` when the target or source application cannot be
resolved — so a boolean would have to answer for cases whose only honest answer is "it depends
what you are going to do about it". Branch on the outcome instead.

Classification is on the HTTP status first and the body second. A `401` whose body will not parse
is still `:credential_rejected`: the SDK reaches intake through a proxy, and a WAF or load
balancer can answer 401 with an HTML page intake never generated. `:transport_error` means one
thing only — no usable HTTP status was obtained because the request never completed (an Excon,
socket, SSL or timeout error). Anything else raised while minting is not a transport error and
propagates.

The body decides exactly one thing, and only on a 2xx: whether a token was actually minted. A
success means a token is there to read — the body parsed and carries a non-empty `token` and the
non-empty `base_url` to cache it under. A 2xx that will not parse, or carries no token, or a
token with no `base_url`, is a `:server_error` keeping its real 2xx status, because intake's
`base_url` is `NOT NULL` and it answers a 4xx rather than minting when the URL resolves to
nothing — so a 2xx missing one is a broken server, not a refused request.

The same verdict is available one level down, without the cache, from
`EndPointBlank::Commands::GenerateAccessToken.token_result(base_url)`, which returns an
`AccessTokenResult` with `outcome`, `status`, `payload` and the same predicates.

Under Rails, protect an inbound endpoint by including the `Authorized` concern in a controller —
it calls `EndPointBlank::Commands::EndpointAuthorize.authorize(request)` before the action, and
raises `EndPointBlank::UnauthorizedError` (which you can rescue with
`rescue_from EndPointBlank::UnauthorizedError` in `ApplicationController`) on a non-201 response:

```ruby
class OrdersController < ApplicationController
  include EndPointBlank::Rails::Authorized
end
```

`EndPointBlank::Commands::EndpointAuthorize.authorize` sends the request's path, HTTP method,
inbound `Authorization` header, app name, resolved endpoint version, and remote IP to
`#{base_url}/api/authorize`, authenticating itself to intake with `Basic`, and caches a positive
(201) result for `cache_ttl` seconds via `EndPointBlank::Commands::AuthenticationCache`. It never
mints or presents a Bearer token for this call: intake already holds this service's own
credential, so exchanging one to present it back would buy nothing.

**Behavior change:** `target_hostname` on the authorize call now comes from the `Host` header
only. It previously came from `request.host`, which reads the last `X-Forwarded-Host` hop. If
your app sits behind a proxy that **rewrites** `Host` (nginx's default; Caddy and most ALBs
preserve it) and you registered the external hostname in the portal, either update the
registered hostname to the internal one the app now reports, or configure the proxy to preserve
`Host`. Deployments where `Host` and `X-Forwarded-Host` agree are unaffected.

The `Authenticated` concern is the lighter sibling: it calls
`EndPointBlank::Commands::BasicAuthenticate.authenticate(request)` before the action and refuses
the same way, but records nothing on the Rack env, sets no deprecation headers and — matching
every other SDK's authenticate path — does not cache intake's answer.

```ruby
class OrdersController < ApplicationController
  include EndPointBlank::Rails::Authenticated
end
```

`EndPointBlank::UnauthorizedError#status` is intake's own verdict, from either concern, so
`rescue_from` can render it directly. 401 and 403 are different remedies and must not be
collapsed:

| intake answered | `error.status` |
| --- | --- |
| 401 | `401` — re-check or re-issue the credential |
| 403 | `403` — ask for a grant covering this endpoint |
| any other non-201 | that status, verbatim |
| nothing at all | `503` — the check could not be made, so nothing judged this caller |

`UnauthorizedError.new(message)` still defaults to 401; the status is an optional second
argument. Raise the instance (`raise UnauthorizedError.new(msg, status)`) rather than
`raise UnauthorizedError, msg` — the two-argument form cannot carry a status.

### Error reporting

Exceptions raised while `EndPointBlank::Middleware::Rack::ReportInteraction` is on the stack are
reported automatically (see [Framework integration](#framework-integration)). To report one
manually:

```ruby
begin
  risky_operation!
rescue => e
  EndPointBlank::Writers::ExceptionWriter.write(e)
  raise
end
```

### Request/response/log reporting

Requests and responses are written automatically by the Rack middleware. Application logs are
sent explicitly:

```ruby
EndPointBlank::Writers::LogWriter.info("cache warmed", { keys: 42 })
EndPointBlank::Writers::LogWriter.warn("slow query", { duration_ms: 820 })
EndPointBlank::Writers::LogWriter.error("payment webhook rejected", { code: "sig_mismatch" })
EndPointBlank::Writers::LogWriter.fatal("out of workers")
```

All writers (`RequestWriter`, `ResponseWriter`, `ExceptionWriter`, `LogWriter`) enqueue their
payload onto a bounded, in-memory queue (`DelayedWriter`, capacity 1000, drop-oldest under
sustained backpressure) drained by `worker_count` background threads that POST batches via `excon`,
six payloads per request. Batches are cut by position, so two identical payloads are two payloads.
Delivery is fire-and-forget and never raises into your request cycle.

A worker thread does not die. A batch can be lost — the intake may be unreachable, or the send path
may raise something nobody anticipated — but the loop catches every `StandardError`, logs it at
`error` level through `EndPointBlank.logger` with a running count of consecutive failures, backs off
(0.1s, doubling, capped at 30s), and keeps draining; the count resets on the first clean pass. Only
an error outside `StandardError` — `SystemExit`, `Interrupt`, `SignalException`, `NoMemoryError`,
i.e. the process itself going down — ends a worker.

A writer may optionally define `on_success(response)` and `on_failure(response)` to hear about each
batch. `on_failure` receives `nil` when the intake never answered at all: `Commands::Http` returns
`nil` once its three attempts are exhausted, which is the absence of a status rather than a failing
one. A writer that defines neither is unaffected.

### Data masking

Mask sensitive data **client-side, before it leaves your process**. Configure an ordered list of
rules; each rule targets one field and masks by a JSONPath, a regex, or both. (Server-side intake
also masks independently, so this is defense in depth.)

```ruby
EndPointBlank.configure do |config|
  config.masking_rules = [
    # Replace any "ssn" field at any depth in the request body.
    { target: "request_body", path: "$..ssn", replacement_value: "***" },
    # Keep first/last 4 of a card number in error messages via backreferences.
    { target: "error_message", regex: "(\\d{4})-\\d{4}-\\d{4}-(\\d{4})", replacement_value: "$1-****-****-$2" }
  ]
  # Optional: runs after the rules; last chance to transform the payload.
  config.mask_hook = ->(payload, record_type) { payload }
end
```

Rules are hashes with symbol (or string) keys.

**Rule fields**

- `target` — exactly one of `"request_body"`, `"request_headers"`, `"path"`, `"response_body"`,
  `"error_message"`.
- `path` — an optional JSONPath (supported subset: `$`, `.name`, `['name']`, `[n]`, `.*` / `[*]`,
  and `..name` for recursive descent). Keys are case-sensitive.
- `regex` — an optional regular expression source string.
- `replacement_value` — the replacement string (default `"..."`).

**Semantics — path scopes, regex matches within.** With only a `path`, the selected node is
replaced entirely. With only a `regex`, every matching string leaf is replaced. With both, the
regex is applied only within the path-selected node(s). When a `regex` is present,
`replacement_value` supports backreferences: `$1`, `$2`, … insert capture groups (`$0` the whole
match; `$$` for a literal `$`). Stacktraces and log messages/data are never masked (there is no
`log` entry in the masking field map).

## Framework integration

### Rails

Nothing to wire up manually. When `::Rails` is defined, `lib/end_point_blank.rb` requires
`EndPointBlank::Rails::Railtie`, which:

- inserts `EndPointBlank::Middleware::Rack::ReportInteraction` into the middleware stack right
  after `ActionDispatch::DebugExceptions`, so every request/response is reported and exceptions
  are captured before Rails' own exception rendering; and
- sets `Configuration.instance.logger ||= Rails.logger`, so `EndPointBlank.logger` writes through
  `Rails.logger` unless you've already configured your own.

Optional concerns for controllers:

```ruby
class ApplicationController < ActionController::Base
  rescue_from EndPointBlank::UnauthorizedError do |e|
    render json: { error: e.message }, status: e.status
  end
end

class OrdersController < ApplicationController
  include EndPointBlank::Rails::Authorized   # authorize inbound requests before each action
  # or: include EndPointBlank::Rails::Authenticated  # authenticate only, no caching
  include EndPointBlank::Rails::Versioned

  version ["v1", "v2"], only: [:index]
end
```

`app_name` falls back to `Rails.application.name.underscore` automatically, so Rails apps
typically only need to configure `client_id` / `client_secret` (and `app_name` only to override
the Rails-derived default).

### Plain Ruby / Sinatra

There's no Rails to auto-load anything, so insert the Rack middleware yourself and set `app_name`
and `env_name` explicitly (via `configure` or `ENDPOINTBLANK_APP_NAME` / `ENDPOINTBLANK_ENV`,
since there's no `Rails.application.name` / `Rails.env` to infer them from):

```ruby
require "sinatra"
require "end_point_blank"

EndPointBlank.configure do |config|
  config.client_id     = ENV.fetch("ENDPOINTBLANK_CLIENT_ID")
  config.client_secret = ENV.fetch("ENDPOINTBLANK_CLIENT_SECRET")
  config.app_name       = "my-sinatra-app"   # or set ENDPOINTBLANK_APP_NAME and omit this
  config.env_name       = "production"       # or set ENDPOINTBLANK_ENV / RACK_ENV and omit this
  config.logger         = Logger.new($stdout)
end

use EndPointBlank::Middleware::Rack::ReportInteraction

get "/" do
  "ok"
end
```

The middleware calls `EndPointBlank::Rack::EnvStore.set(env)`, reports the request via
`RequestWriter`, invokes the app, and — in an `ensure` — reports the response via `ResponseWriter`
and clears the env store, reporting any raised exception via `ExceptionWriter` along the way. It
reads/writes plain Rack request objects (`::Rack::Request`), so it works identically under any
Rack-compatible server or framework, not only Sinatra.

## Management API

`EndPointBlank::Management::Client` manages your organization's EndPointBlank setup from code:
API packages, clients and their invites, package assignments, direct grants, applications,
environments, runtime credentials, and the managed clients you run for your customers. It calls
app_portal's management API (`https://app.endpointblank.com/api/v1`). See the
[guide](https://app.endpointblank.com/docs/management-api) and the
[reference](https://app.endpointblank.com/docs/management-api-reference).

It is plain Ruby, usable from a script, a job or a console as well as a Rails app, and it is
**separate from the runtime configuration above**. It authenticates only with a management API
key (create one in the portal under Settings > API Keys), sent as
`Authorization: Bearer epb_mk_...`. It never sends your runtime `client_id`/`client_secret`, never
calls intake, and never shows the key in `inspect`, `to_s` or an error message. A key without the
`epb_mk_` prefix is refused when the client is built, with `EndPointBlank::ConfigurationError`.

### Quick start

```ruby
require "end_point_blank"

mgmt = EndPointBlank::Management::Client.new(api_key: ENV.fetch("EPB_MGMT_KEY"))

mgmt.organization  # => {"id" => "...", "name" => "Acme", "slug" => "acme", "key" => {"name" => "ci", "scope" => "write"}, ...}

# One page at a time (limit 1..100, default 50) ...
page = mgmt.applications.list(limit: 20)
page.data         # => [{"id" => "...", "name" => "Orders", ...}, ...]
page.next_cursor  # => pass as `after:` for the next page; nil on the last one

# ... or every item, fetching pages as it goes (an Enumerator without a block).
mgmt.applications.each { |application| puts application["name"] }
names = mgmt.api_packages.each(limit: 100).map { |package| package["name"] }
```

Every call answers what the API sent, decoded from JSON into Hashes with String keys: the
resource itself (the response's `data`), a `Page` for a list, and `{"id" => ..., "deleted" => true}`
for a delete. `api_packages.add_endpoint` and `remove_endpoint` answer the whole body,
`{"data" => ..., "warnings" => [...]}`, so the `assignment_derives_nothing` warnings are not lost.
Optional keyword arguments left `nil` are not sent.

### Invite a client and assign an API package

```ruby
# Environment names are unique per organization, and "production" is reserved for the one every
# organization already has; look an existing one up with mgmt.environments.each instead.
staging = mgmt.environments.create(name: "staging", domain: "staging.example.com")
orders  = mgmt.applications.create(name: "Orders",
                                   environment_base_urls: { staging["id"] => "https://orders.staging.example.com" })

package = mgmt.api_packages.create(name: "Orders read")

# An application's endpoints are listed once its runtime SDK has reported them, so a just-created
# application has none yet. Publish one endpoint when it is there, else the whole application
# (endpoint_id nil covers every endpoint, including ones reported later).
endpoint = mgmt.endpoints.each(application_id: orders["id"]).find { |e| e["path"] == "/orders" && e["action"] == "GET" }
mgmt.api_packages.add_endpoint(package["id"], application_id: orders["id"], endpoint_id: endpoint&.fetch("id"),
                                              environment_id: staging["id"])
```

Then give a client the package in one of two ways; doing both for the same package and environment
is refused with `already_assigned`.

```ruby
# Either: set it up on the invite, and it is assigned the moment the client accepts.
globex = mgmt.clients.invite(
  name: "Globex",
  contacts: [{ email: "dev@globex.example", first_name: "Hank", last_name: "Scorpio" }],
  packages: [{ api_package_id: package["id"], environment_id: staging["id"] }]
)
globex["invite_code"]  # send this to the client; it accepts from its own EndPointBlank organization

# Or: invite first, then assign (pending until the client accepts, active after) and grant directly.
initrode = mgmt.clients.invite(name: "Initrode")
mgmt.package_assignments.assign(initrode["id"], api_package_id: package["id"], environment_id: staging["id"])
mgmt.grants.create(initrode["id"], target_application_id: orders["id"], environment_id: staging["id"])
```

### Runtime credentials

```ruby
app_env = mgmt.applications.list_environments(orders["id"]).first
credential = mgmt.credentials.create(application_environment_id: app_env["id"])
credential["client_id"]
credential["client_secret"]  # shown once, here and nowhere else: store it now

rotated = mgmt.credentials.rotate(credential["id"])
rotated["client_secret"]     # the new secret; the old one keeps working for the grace window

mgmt.credentials.revoke(credential["id"])
```

`list` and `get` answer metadata only (`secret_last_4`, never the secret). This SDK never logs a
secret, the key, or any request or response body.

### Managed clients

A managed client is an organization you create and run for a customer until they claim it.
`for_managed_client(id)` gives the same applications, environments and credentials calls, sent
under `/api/v1/clients/:client_id/`:

```ruby
customer = mgmt.clients.create_managed(name: "Initech")
initech  = mgmt.for_managed_client(customer["id"])

# The managed client's organization already has a "production" environment (the name is
# reserved); create others alongside it.
initech_staging = initech.environments.create(name: "staging", domain: "staging.initech.example")
billing_url = "https://billing.staging.initech.example"
app = initech.applications.create(name: "Initech billing",
                                  environment_base_urls: { initech_staging["id"] => billing_url })
app_env = initech.applications.list_environments(app["id"]).first
secret = initech.credentials.create(application_environment_id: app_env["id"])["client_secret"]

# Grant it your APIs like any accepted client (package and staging from the example above) ...
mgmt.package_assignments.assign(customer["id"], api_package_id: package["id"], environment_id: staging["id"])

# ... and hand it over: the customer gets an email, and claiming rotates every credential you issued.
initech.claim_invite(email: "it@initech.example")
```

Once claimed, the managed client's calls answer `not_found`. Remove an unclaimed one with
`mgmt.clients.delete(customer["id"])` after revoking its credentials.

### Errors, retries and idempotency

Every refusal raises `EndPointBlank::Management::Error` (a subclass of `EndPointBlank::Error`)
with `code`, `message`, `details`, `status`, `retry_after`, `location` and `request_id`. Match on
`code`, which is stable; `message` is for people. `EndPointBlank::Management::ErrorCodes` has a
constant for every code the API documents, and an unknown code still raises with that code.

```ruby
codes = EndPointBlank::Management::ErrorCodes

begin
  mgmt.clients.invite(name: "Umbrella")
rescue EndPointBlank::Management::Error => e
  case e.code
  when codes::PLAN_LIMIT        then warn "upgrade your plan to add clients"            # 402
  when codes::VALIDATION_FAILED then warn "invalid fields: #{e.details.inspect}"        # 422
  when codes::NOT_FOUND         then warn "no such resource"                            # 404
  when codes::INSUFFICIENT_SCOPE then warn "this is a read-only key"                    # 403
  else raise
  end
end
```

The SDK raises three codes of its own: `connection_error` (no answer at all; `status` is nil),
`http_error` (an error answer that is not the API's JSON, e.g. from a proxy) and
`invalid_response` (a success answer that is not JSON).

- **Idempotency.** Every POST sends an `Idempotency-Key`: a random UUID unless you pass
  `idempotency_key:` (1 to 255 characters), and a retry sends the same key, so a POST is never run
  twice. A credential `create` or `rotate` retried after the first one succeeded raises
  `idempotency_replay_unavailable` instead of replaying the secret: read or list the credential
  (rotate it if you never got the secret).
- **Retries.** A 429 `rate_limited` is retried after its `Retry-After` seconds (1 second
  when it has none). A 5xx
  (`internal_server_error`, `audit_unavailable`, `intake_unavailable`) or a request that got no
  answer is retried with backoff for GET, DELETE and POST, never for PATCH.
  `idempotency_request_in_progress` is retried shortly with the same key. 4xx refusals are never
  retried.

| `Client.new` option | Env var fallback | Default | Notes |
|---|---|---|---|
| `api_key` | `ENDPOINTBLANK_MANAGEMENT_KEY` | none (required) | A management API key, `epb_mk_...`. |
| `base_url` | `ENDPOINTBLANK_MANAGEMENT_BASE_URL` | `https://app.endpointblank.com` | app_portal, not intake. |
| `max_retries` | — | `2` | Retries after the first attempt; `0` turns them off. |
| `max_retry_wait` | — | `60` | The longest single wait, in seconds; a longer `Retry-After` raises instead. |
| `connect_timeout` / `read_timeout` | — | `5` / `30` | Seconds. |
| `sleeper` | — | `Kernel#sleep` | Called with the seconds before each retry (replace it in tests). |
| `excon_options` | — | `{}` | Extra `Excon.new` options, e.g. a proxy. |

In a Rails app, set the defaults once in an initializer, apart from `EndPointBlank.configure`:

```ruby
# config/initializers/end_point_blank_management.rb
EndPointBlank::Management.configure do |m|
  m.api_key = Rails.application.credentials.dig(:end_point_blank, :management_key)
  m.max_retries = 3
end

EndPointBlank::Management.client.organization  # a Client built from that configuration
```

## Development

```sh
bundle install
bundle exec rspec
bundle exec rubocop
```

`bundle exec rspec` runs the full suite, including specs that assert the framework-agnostic core
behaves correctly with `::Rails` undefined (`spec/no_rails_spec.rb`,
`spec/generate_access_token_no_rails_spec.rb`,
`spec/route_pattern_finder_and_version_finder_no_rails_spec.rb`).

## License

No `LICENSE` file or `spec.license` is currently present in this repository. Treat usage as
proprietary/all-rights-reserved until a license is added, or confirm terms with the repository
owners.

## Links

- Repository: https://github.com/EndPointBlank/end_point_blank_rails
- Issues: https://github.com/EndPointBlank/end_point_blank_rails/issues
