# Framework-agnostic `end_point_blank` (Ruby) — Design

## Goal
Make the `end_point_blank` gem run in **plain Ruby / Sinatra**, not just Rails, by decoupling the core from `::Rails`, and add **`ENDPOINTBLANK_*`** environment-variable configuration. Rails stays supported as a thin, auto-loaded adapter. This is the first slice of the client-lib parity work (#1); env-var config for Java/JS/Python/Elixir is a follow-up.

## Context (current state)
- RSpec suite of 6 specs (`bundle exec rspec`) — the refactor's safety net.
- The Rails concerns + railtie (`end_point_blank/rails/*`) are **already** gated by `if defined?(::Rails)` in `lib/end_point_blank.rb`. Good — packaging is half-done.
- Runtime coupling to `::Rails` is three things: **logging** (`::Rails.logger` in ~10 files), **`app_name`** (`::Rails.application.name`), and **route/host/port/env introspection** (`commands/endpoint_update.rb`, `commands/route_pattern_finder.rb`). The introspection is not called from the core request/authorize path — only from Rails-gated code.
- `Configuration` is a singleton (`Configuration.instance`) with `attr_accessor :client_id, :client_secret, :base_url, :log_base_url, …`, an `app_name` method that falls back to `::Rails.application.name`, and no env-var reading.
- `EndPointBlank::Loggers::Logger` exists but is inconsistent (`error/warn/fatal` → `::Rails.logger`; `debug`/`info` write via `Writers`; ). It's the seam to build on.

## Design

### 1. Pluggable logging (the pervasive coupling)
Introduce a single logger seam:
- `EndPointBlank.logger` — module accessor. Resolution order: `Configuration.instance.logger` (if set) → a memoized default `::Logger.new($stdout)` (level `INFO`). `EndPointBlank.logger=` setter also supported.
- `Configuration` gains a `logger` accessor (default `nil` → falls through to the stdout default).
- Replace **every** `::Rails.logger.X` / `Rails.logger.X` call in the core (access_tokens, commands/*, writers/delayed_writer, middleware/rack/report_interaction, loggers/logger) with `EndPointBlank.logger.X`.
- `Loggers::Logger`'s `error/warn/fatal` route through `EndPointBlank.logger`; its `debug`/`info` Writer behavior is unchanged (that's interaction-emission, a separate concern).
- The Rails adapter (railtie) sets `Configuration.instance.logger = ::Rails.logger` on boot, so Rails apps log through Rails exactly as today.

### 2. Env-var configuration (`ENDPOINTBLANK_*`)
`Configuration` reads env vars as fallbacks when a value isn't set in the `configure` block. Precedence: **explicit `configure` value > `ENDPOINTBLANK_*` env var > built-in default**. Mapping:

| setting | env var |
|---------|---------|
| `client_id` | `ENDPOINTBLANK_CLIENT_ID` |
| `client_secret` | `ENDPOINTBLANK_CLIENT_SECRET` |
| `base_url` | `ENDPOINTBLANK_BASE_URL` |
| `log_base_url` | `ENDPOINTBLANK_LOG_BASE_URL` |
| `app_name` | `ENDPOINTBLANK_APP_NAME` |

Implemented so an unset accessor returns the env value if present (e.g. `client_id` returns `@client_id || ENV["ENDPOINTBLANK_CLIENT_ID"]`), keeping the singleton + `configure` API intact.

### 3. `app_name` without Rails
`Configuration#app_name` resolution: explicit `@app_name` → `ENDPOINTBLANK_APP_NAME` → (only if `defined?(::Rails)`) `::Rails.application.name.underscore` → `nil`/raise-with-clear-message. The Rails adapter may still default it from the Rails app; non-Rails apps set it via `configure` or the env var. Same treatment for the `::Rails.application.class.module_parent_name` fallback in `endpoint_update.rb` (that path is Rails-only anyway).

### 4. Rails-only introspection stays in the adapter
`commands/endpoint_update.rb` and `commands/route_pattern_finder.rb` (routes, `force_ssl`, host, port, `::Rails.env`, `::Rails.application.routes`) are inherently Rails-specific. They remain, but every `::Rails.*` call in them is reached only under Rails (they're invoked from the railtie / Rails concerns). Requiring the files is fine (load-time touches no `::Rails`); we only guarantee the **core request/authorize + logging path never calls them** without Rails. Non-Rails apps get no automatic endpoint registration — acceptable (the core Rack middleware is enough).

### 5. Packaging
- `lib/end_point_blank.rb` already loads core files unconditionally and `rails/*` + railtie under `if defined?(::Rails)`. Keep. Verify no core file raises at **load** time when `::Rails` is undefined.
- The gemspec stays Rails-free (already no railties dependency).
- The `end_point_blank_sinatra` sample app (requires the gem, no Rails) becomes the real-world validation: it should boot and the middleware should emit interactions without `::Rails`.

### 6. Testing (extend RSpec)
- **Logger:** with `::Rails` undefined, `EndPointBlank.logger` returns a stdout `Logger`; a configured `config.logger` is honored; `Loggers::Logger.error` routes to it. (Assert via a captured/stubbed logger.)
- **Env config:** `ENDPOINTBLANK_CLIENT_ID` etc. are read when `configure` doesn't set them; explicit `configure` wins over env; env wins over default.
- **No-Rails smoke:** in an example where `::Rails` is not defined, `require "end_point_blank"` succeeds and a representative core flow (e.g. a `report_interaction` write, mocked HTTP) runs without raising `NameError: ::Rails`.
- Adjust existing specs that stub `::Rails.logger` to stub `EndPointBlank.logger` instead.
- `bundle exec rspec` green; `rubocop` clean (Rakefile runs both).

## Out of scope (follow-ups)
- Env-var config for the Java / JS / Python / Elixir SDKs (separate slice of #1).
- A dedicated Sinatra/Rack adapter class (core middleware is enough for now).
- Non-Rails automatic endpoint/route registration.
- Renaming the gem or changing the public `configure` API shape.
