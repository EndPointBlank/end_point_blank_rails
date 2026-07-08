# Framework-agnostic `end_point_blank` (Ruby) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps use `- [ ]` tracking. This is a Ruby gem: RSpec (`bundle exec rspec`) + RuboCop (`bundle exec rubocop`).

**Goal:** Decouple the gem's core from `::Rails` (pluggable logging, env-var config, Rails-only introspection gated) so it runs in plain Ruby / Sinatra, with Rails as an auto-loaded adapter.

**Architecture:** A single logger seam (`EndPointBlank.logger`), `Configuration` reading `ENDPOINTBLANK_*`, and the railtie wiring Rails specifics. Core never calls `::Rails` except through these seams.

## Global Constraints
- Design source of truth: `docs/superpowers/specs/2026-07-08-framework-agnostic-core-design.md`.
- Config precedence everywhere: **explicit `configure` value > `ENDPOINTBLANK_*` env > built-in default**.
- The public API (`EndPointBlank.configure { |c| ... }`, `Configuration.instance`) does not change shape.
- After each task: `bundle exec rspec` green and `bundle exec rubocop` clean.
- Do NOT touch `HARDENING_REPORT.md` (pre-existing, untracked, not ours).

---

### Task 1: Pluggable logging seam

**Files:**
- Modify: `lib/end_point_blank.rb` (logger accessor), `lib/end_point_blank/configuration.rb` (`logger` attr), `lib/end_point_blank/loggers/logger.rb`, `lib/end_point_blank/rails/railtie.rb`
- Modify (replace `::Rails.logger`): `lib/end_point_blank/access_tokens.rb`, `commands/http.rb`, `commands/basic_authenticate.rb`, `commands/generate_access_token.rb`, `commands/endpoint_authorize.rb`, `commands/endpoint_update.rb`, `writers/delayed_writer.rb`, `middleware/rack/report_interaction.rb`
- Test: `spec/logger_spec.rb` (new), and adjust any spec that stubs `::Rails.logger`

**Interfaces (Produces):** `EndPointBlank.logger` → a `::Logger`-like object; `EndPointBlank.logger=`; `Configuration#logger` / `#logger=`.

- [ ] **Step 1:** Add to `EndPointBlank` (in `end_point_blank.rb`): `def self.logger; Configuration.instance.logger || (@default_logger ||= ::Logger.new($stdout)); end` and `def self.logger=(l); Configuration.instance.logger = l; end`. `require "logger"` at the top.
- [ ] **Step 2:** `Configuration` — add `:logger` to `attr_accessor` (default `nil`).
- [ ] **Step 3 (TDD):** `spec/logger_spec.rb` (fail first):
  - with `::Rails` not defined, `EndPointBlank.logger` is a `Logger` writing to `$stdout`;
  - `EndPointBlank.configure { |c| c.logger = my_logger }` → `EndPointBlank.logger == my_logger`;
  - `EndPointBlank::Loggers::Logger.error("x")` calls `EndPointBlank.logger.error`.
- [ ] **Step 4:** In `loggers/logger.rb`, change `error/warn/fatal` to `EndPointBlank.logger.error/warn/fatal` (leave `debug`/`info` Writer behavior).
- [ ] **Step 5:** Replace every remaining `::Rails.logger.X` / `Rails.logger.X` in the 8 core files with `EndPointBlank.logger.X`. (`delayed_writer.rb` already guards — simplify to `EndPointBlank.logger.warn`.)
- [ ] **Step 6:** In `rails/railtie.rb`, on boot set `EndPointBlank::Configuration.instance.logger ||= ::Rails.logger` (initializer). So Rails apps log via Rails unchanged.
- [ ] **Step 7:** Update any existing spec stubbing `::Rails.logger` to stub `EndPointBlank.logger`. `bundle exec rspec` green, `rubocop` clean. Commit `feat: pluggable EndPointBlank.logger, decouple core logging from ::Rails`.

### Task 2: Env-var config + Rails-free `app_name`

**Files:**
- Modify: `lib/end_point_blank/configuration.rb`
- Test: `spec/configuration_spec.rb` (new or extend)

**Interfaces:** `Configuration#client_id/#client_secret/#base_url/#log_base_url/#app_name` honor `ENDPOINTBLANK_*` fallbacks.

- [ ] **Step 1 (TDD):** `spec/configuration_spec.rb` (fail first), resetting the singleton + `ENV` per example:
  - unset `client_id` returns `ENV["ENDPOINTBLANK_CLIENT_ID"]`; same for `client_secret`, and `base_url`/`log_base_url`/`app_name`;
  - explicit `configure` value beats the env var; env var beats the built-in default (`base_url` default stays `https://in.endpointblank.com` when neither set);
  - `app_name` with `::Rails` undefined + `ENDPOINTBLANK_APP_NAME` set returns that; unset + no Rails → `nil` (no `NameError`).
- [ ] **Step 2:** Implement env fallbacks. For `client_id`/`client_secret` (no default): `@client_id || ENV["ENDPOINTBLANK_CLIENT_ID"]` via overridden readers. For `base_url`/`log_base_url`: default applied only when both ivar and env are nil. `app_name`: `@app_name || ENV["ENDPOINTBLANK_APP_NAME"] || (::Rails.application.name.underscore if defined?(::Rails))`.
- [ ] **Step 3:** `bundle exec rspec` green, `rubocop` clean. Commit `feat: ENDPOINTBLANK_* env-var configuration + Rails-free app_name`.

### Task 3: No-Rails packaging + smoke test

**Files:**
- Modify (only if a load-time/core-path `::Rails` reference is found): the offending file
- Test: `spec/no_rails_spec.rb` (new)

- [ ] **Step 1:** Grep the core (everything except `lib/end_point_blank/rails/*`, `commands/endpoint_update.rb`, `commands/route_pattern_finder.rb`) for any remaining `::Rails` / `Rails.` reference. Each must be either gone (Task 1) or guarded by `defined?(::Rails)`. Fix any stray one by routing through a seam or guarding.
- [ ] **Step 2 (TDD):** `spec/no_rails_spec.rb`:
  - `require "end_point_blank"` succeeds with `::Rails` not defined (it isn't, in specs);
  - a representative core flow runs without a `NameError: ::Rails` — e.g. build a `Configuration` via `configure`, run a `Middleware::Rack::ReportInteraction` call (or a `Writers` write) with HTTP stubbed, asserting no `::Rails`-related error is raised. (Stub `EndPointBlank::Commands::Http` / excon so nothing leaves the process.)
- [ ] **Step 3:** Confirm the Rails-only introspection (`endpoint_update`, `route_pattern_finder`) is never reached in this flow. `bundle exec rspec` green, `rubocop` clean. Commit `test: no-Rails smoke coverage for the framework-agnostic core`.

## Notes
- `Configuration.instance` is a singleton — specs must reset it between examples (a `reset!` helper or `Singleton.__init__`), and save/restore `ENV` keys they touch.
- Keep changes minimal and mechanical in Task 1 (it's a wide but shallow find-replace); the behavior change is only "logs go through a seam."
- Do not introduce a `railties` dependency; the railtie is already loaded only under `defined?(::Rails)`.
