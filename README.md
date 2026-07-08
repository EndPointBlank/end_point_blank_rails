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
| `worker_count` | — | `4` | Currently unused by the delayed writer (which always spins up 2 threads); reserved. |
| `token_ttl` | — | `nil` | Optional TTL (seconds) requested when generating a `Bearer` access token. |
| `cache_ttl` | — | `300` | TTL (seconds) for the authorization decision cache. |
| `masking_rules` | — | `[]` | Ordered list of masking rule hashes — see [Data masking](#data-masking). |
| `mask_hook` | — | `nil` | Optional `->(payload, record_type_string) { payload }` run after `masking_rules`. |
| `version_finder` | — | `nil` | Optional `->(request) { "1" }` overriding `EndPointBlank::Commands::VersionFinder`'s default header/param/path detection. |
| `application_version` | — | `nil` | Reserved for reporting your app's own version. |

Note: there is also a bare `environment` accessor on `Configuration`, but it is not read by any
code path in this gem (the real per-request environment name is `env_name`, described above) — do
not rely on it.

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

`EndPointBlank::Authorization.header(hostname = nil)` builds the outbound `Authorization` header
used by the gem's own HTTP calls: a cached `Bearer` token for `hostname` when one is available
(via `EndPointBlank::AccessTokens`), otherwise `Basic` credentials built from `client_id` /
`client_secret`.

```ruby
EndPointBlank::Authorization.header               # => "Basic ..."
EndPointBlank::Authorization.header("api.example.com") # => "Bearer ..." if a token is cached
```

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
`#{base_url}/api/authorize`, and caches a positive (201) result for `cache_ttl` seconds via
`EndPointBlank::Commands::AuthenticationCache`.

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
sustained backpressure) drained by two background threads that POST batches via `excon`. Delivery
is fire-and-forget and never raises into your request cycle.

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
