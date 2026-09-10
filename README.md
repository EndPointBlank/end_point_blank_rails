# EndPointBlank (Ruby)

The Ruby client for [EndPointBlank](https://endpointblank.com): API endpoint tracking, endpoint
authorization, error/request/response/log reporting, and client-side data masking — with a
**framework-agnostic core** that runs in plain Ruby or Sinatra, plus a Rails adapter that
auto-loads (railtie + middleware) when Rails is present.

## Capabilities

- **Endpoint tracking** — every request/response passing through the Rack middleware is reported.
- **Authorization** — outbound calls to other EndPointBlank-protected services are signed
  (`Basic` client-credential or cached `Bearer` token), and inbound requests can be authorized
  against the EndPointBlank service before your action runs.
- **Error, request, response, and log reporting** — background, queued, non-blocking delivery to
  the EndPointBlank intake API.
- **Client-side data masking** (`EndPointBlank::Masking` / `masking_rules`) — strip or redact
  sensitive fields from payloads *before* they leave your process, as defense in depth on top of
  server-side masking.
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

`EndPointBlank.configure { |c| ... }` yields the `EndPointBlank::Configuration` singleton.
Every setting listed below can be set explicitly in that block, and most also fall back to an
`ENDPOINTBLANK_*` environment variable, then to a built-in default.

**Precedence: explicit `configure` value > `ENDPOINTBLANK_*` environment variable > default.**

| `configure` setting | Env var fallback | Default | Notes |
|---|---|---|---|
| `client_id` | `ENDPOINTBLANK_CLIENT_ID` | `nil` | Used to build the `Basic` authorization header. |
| `client_secret` | `ENDPOINTBLANK_CLIENT_SECRET` | `nil` | Paired with `client_id`. |
| `base_url` | `ENDPOINTBLANK_BASE_URL` | `https://in.endpointblank.com` | Base for access-token, authorize, and endpoint-update APIs. |
| `log_base_url` | `ENDPOINTBLANK_LOG_BASE_URL` | `https://log.endpointblank.com` | Base for error/request/response/log reporting APIs. |
| `app_name` | `ENDPOINTBLANK_APP_NAME` | `Rails.application.name.underscore` if Rails is defined, else `nil` | Identifies your app to EndPointBlank. |
| `env_name` | `ENDPOINTBLANK_ENV` | `RACK_ENV`, then `APP_ENV`, then `Rails.env` if defined, else `"production"` (resolved per-request by `SessionConfiguration.env_name`, not read directly off `Configuration`) | The environment name reported with each request/response payload. |
| `logger` | — | A `::Logger.new($stdout, level: ::Logger::INFO)`, or `Rails.logger` under Rails (set by the railtie) | Any object with `.debug`/`.info`/`.warn`/`.error`/`.fatal` works. |
| `worker_count` | — | `4` | Number of background threads draining the delayed writer's queue. Falls back to 2 when set to `nil`. |
| `token_ttl` | — | `nil` | Optional TTL (seconds) requested when generating a `Bearer` access token. |
| `cache_ttl` | — | `300` | TTL (seconds) for the authorization decision cache. |
| `trust_proxy_headers` | — | `true` | Whether the per-request `scheme`/`host`/`port` report honors `X-Forwarded-Proto`/`-Host`/`-Port`. See [Reported base URL](#reported-base-url). |
| `masking_rules` | — | `[]` | Ordered list of masking rule hashes — see [Data masking](#data-masking). |
| `mask_hook` | — | `nil` | Optional `->(payload, record_type_string) { payload }` run after `masking_rules`. |
| `version_finder` | — | `nil` | Optional `->(request) { "1" }` overriding `EndPointBlank::Commands::VersionFinder`'s default header/param/path detection. |
| `application_version` | — | `nil` | Reserved for reporting your app's own version. |

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

`EndPointBlank::Authorization.header(base_url = nil)` builds the outbound `Authorization` header
used by the gem's own HTTP calls: a cached `Bearer` token covering `base_url` when one is
available (via `EndPointBlank::AccessTokens`), otherwise `Basic` credentials built from
`client_id` / `client_secret` -- which covers both giving no target and a token that could not
be obtained.

```ruby
EndPointBlank::Authorization.header # => "Basic ..."

# Pass the URL you are about to call, NOT a hostname.
# Strip any query string or fragment first -- intake rejects both.
EndPointBlank::Authorization.header("https://api.example.com/orders") # => "Bearer ..." if a token is cached
```

The argument is the URL you are about to call. intake matches it against registered base URLs by
longest path prefix, so you need not know how the target registered itself -- `header` for
`https://api.example.com/orders/42` reuses a token already cached for
`https://api.example.com/orders`. `EndPointBlank::AccessTokens` caches one token per base URL
intake resolves to, not one per process, so a service that calls several targets holds a token
for each. A URL that does not match character-for-character (a different case, a query string,
an unregistered path) simply misses and mints a new token -- it never guesses.

### Why a token could not be minted

`EndPointBlank::AccessTokens.token` answers with a token String or `nil`, which is all most
callers need. When `nil` is not enough — when you want to know whether retrying could possibly
help — ask what went wrong:

```ruby
url = "https://api.example.com/orders"

if EndPointBlank::AccessTokens.token(url).nil?
  failure = EndPointBlank::AccessTokens.last_failure(url)

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

`last_failure` returns `nil` once a mint for that URL succeeds again, so it never reports a
problem that has already cleared. A `Failure` carries `base_url`, `outcome`, `status` (the HTTP
status, or `nil` when no usable one was obtained), `reason`, and `at`, and answers
`#credential_rejected?`, `#request_rejected?`, `#server_error?` and `#transport_error?`.

There is deliberately no `#retriable?` or other single retry/no-retry boolean. Retrying a `400`
or a `422` is exactly as futile as retrying a `401` — intake answers `400` for an invalid
`token_ttl` or a missing `base_url`, and `422` when the target or source application cannot be
resolved — so a boolean would have to answer for cases whose only honest answer is "it depends
what you are going to do about it". Branch on the outcome instead.

Classification is on the HTTP status first and the body second. A `401` whose body will not parse
is still `:credential_rejected`: the SDK reaches intake through a proxy, and a WAF or load
balancer can answer 401 with an HTML page intake never generated. `:transport_error` means one
thing only — no usable HTTP status was obtained.

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
sustained backpressure) drained by `worker_count` background threads that POST batches via `excon`.
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
