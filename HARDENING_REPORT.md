# Hardening report — end_point_blank (Rails/Ruby client lib) — P2 #14

Branch: `harden-timeouts-bounded-queue` (off `master`, not pushed)

## Goal

Bring this lib's reliability posture in line with the Elixir sibling lib,
which was hardened with per-attempt HTTP timeouts (connect 3s / read 5s)
and a bounded, drop-oldest background send queue (cap 1000, throttled
warning on drop).

## Gap 1 — Excon calls with no timeout

### Every `Excon.` call site in the lib (confirmed via `grep -rn "Excon\." lib/`)

| File | Line | Call |
|---|---|---|
| `lib/end_point_blank/commands/http.rb` | 23 | `Excon.post` (shared fire-and-forget POST helper, used by `DirectWriter`) |
| `lib/end_point_blank/commands/generate_access_token.rb` | 20 | `Excon.post` (access-token exchange) |
| `lib/end_point_blank/commands/endpoint_update.rb` | 30 | `Excon.post` (endpoint/route registration) |

All three are the only `Excon.*` calls in the lib. No other `Excon.new`/etc. exist.

### Fix

Added a single shared constant in `lib/end_point_blank/commands/http.rb`:

```ruby
CONNECT_TIMEOUT = 3
READ_TIMEOUT    = 5
TIMEOUT_OPTIONS = { connect_timeout: CONNECT_TIMEOUT, read_timeout: READ_TIMEOUT }.freeze
```

- `Http.post` now passes `**TIMEOUT_OPTIONS` directly.
- `generate_access_token.rb` and `endpoint_update.rb` each `require_relative 'http'`
  and splat `**EndPointBlank::Commands::Http::TIMEOUT_OPTIONS` into their own
  `Excon.post` calls, so the values live in exactly one place.

### Timeout error handling

`Excon::Error::Timeout` is a subclass of `Excon::Error` (verified against the
installed excon 1.5.0 source), so:

- `Http.post`'s existing `rescue Excon::Error => e` already covers timeouts —
  it retries up to `MAX_ATTEMPTS` (3) then logs and returns `nil`. No caller
  ever sees an exception.
- `generate_access_token.rb`'s existing `rescue => e` (StandardError) already
  covered timeouts too.
- `endpoint_update.rb` had a **latent bug**: `rescue Excon::Error::Socket,
  Excon::Error::Connection => e`. `Excon::Error::Connection` **does not
  exist** in excon 1.5.0 (only `Excon::Error::Socket`, `Excon::Error::Timeout`,
  etc. are defined under `Excon::Error`). Because Ruby resolves rescue-clause
  constants lazily, this clause would silently work until an exception was
  actually raised inside the `begin` block, at which point evaluating
  `Excon::Error::Connection` would raise `NameError` and crash the caller —
  i.e. a network blip or a timeout during endpoint registration would have
  thrown `NameError` instead of being handled gracefully. Fixed by rescuing
  `Excon::Error` broadly (matching the pattern in `http.rb`), which now also
  correctly covers `Excon::Error::Timeout`.

### Incidental fix required to exercise the above in tests

`lib/end_point_blank/authorization.rb` calls `Base64.encode64` for the Basic
auth header path but never `require 'base64'`. On Ruby 3.4 `base64` was
removed from default gems, so this raised `NameError` / `LoadError` the
moment that code path executed (which is exactly the path exercised in the
`endpoint_update` timeout test, since it needs an `Authorization.header` call
with no cached token). Fixed by adding `require 'base64'` in
`authorization.rb` and declaring `spec.add_dependency "base64"` in the
gemspec (ran `bundle install`, updating `Gemfile.lock`). This was a real
reliability bug independent of this task — any Basic-auth call path in this
gem on Ruby >= 3.4 without `base64` explicitly in the app's own Gemfile would
have crashed.

## Gap 2 — unbounded background queue

`lib/end_point_blank/writers/delayed_writer.rb` used a plain `Queue.new`
(unbounded). During an intake outage, the 2 background drain threads block
on failed/slow POSTs and the queue grows without bound → OOM risk.

### Fix

`Queue` has no `max` option, so the bound is implemented explicitly:

- `MAX_QUEUE_SIZE = 1000`.
- `enqueue` (public API, accepts a single payload or an array, unchanged
  signature) now routes each item through `enqueue_one`, which is guarded by
  a `Mutex` (`enqueue_mutex`) so the check-then-drop-then-push sequence is
  atomic across concurrent producer threads (the request/response/log/error
  writer call paths).
- If `queue.size >= MAX_QUEUE_SIZE` when a new item arrives, the **oldest**
  item is dropped first (`pop_additional`, a non-blocking `Queue#pop(true)`,
  which removes from the front of the FIFO `Queue`), then the new item is
  pushed. Net effect: queue never exceeds 1000, newest items win.
- Drop warnings are throttled: `note_drop` tracks a drop counter and only
  logs (via `log_warning`, which prefers `::Rails.logger.warn` and falls
  back to `Kernel#warn` when Rails isn't loaded) at most once per
  `WARN_THROTTLE_SECONDS` (30s), with the message including how many items
  were dropped since the last warning — so a sustained outage doesn't itself
  become a logging flood.
- The existing 2-thread drain model (`start_threads`) is unchanged in
  structure; internal `@queue` access was switched to a `queue` reader
  (`@queue ||= Queue.new`) so both the drain threads and the new bounded
  `enqueue_one` share the same lazily-initialized queue, and so tests can
  instantiate a bare object that mixes in `DelayedWriter` and drive
  `enqueue`/`queue` without needing to spin up the background threads.

## Sinatra coverage

Confirmed: `end_point_blank_sinatra/Gemfile` depends on
`gem 'end_point_blank', path: '../end_point_blank_rails'` and
`end_point_blank_sinatra/app.rb` does `require 'end_point_blank'`, which is
this gem's single entry point (`lib/end_point_blank.rb`) that requires every
file touched here (`commands/http`, `commands/generate_access_token`,
`commands/endpoint_update`, `writers/delayed_writer`, `authorization`).
There is no Sinatra-specific fork of any of this code. **Sinatra is
covered.**

## Tests added (TDD: written first, confirmed red against the pre-fix code, then made green)

- `spec/commands_http_spec.rb` — asserts `Excon.post` is called with
  `connect_timeout`/`read_timeout` matching the shared constants; asserts a
  raised `Excon::Error::Timeout` is retried `MAX_ATTEMPTS` times, logged, and
  returns `nil` without raising.
- `spec/generate_access_token_spec.rb` — asserts the same timeout options
  reach `Excon.post` for the access-token exchange; asserts a timeout
  doesn't raise.
- `spec/endpoint_update_spec.rb` — asserts the same timeout options reach
  `Excon.post` for endpoint registration; asserts a timeout doesn't raise
  and is logged via `Rails.logger.warn` (this is the test that caught both
  the `Excon::Error::Connection` NameError bug and the missing
  `require 'base64'`).
- `spec/delayed_writer_spec.rb` — mixes `DelayedWriter` into a bare test
  class (without starting background threads, so the queue can be inspected
  synchronously): asserts the queue never exceeds `MAX_QUEUE_SIZE`, asserts
  the oldest items are dropped first (FIFO order preserved for survivors),
  asserts normal FIFO enqueue/dequeue when under the cap, asserts array-form
  `enqueue` also respects the bound, and asserts `log_warning` is called
  only **once** across 50 drops (throttling), not once per drop.

All four spec files were confirmed to fail (9 of 11 new examples red) against
the original code before implementing the fix, then confirmed green after.

## Test evidence

```
$ bundle exec rspec
...
49 examples, 0 failures
```

Also ran the project's actual CI commands directly:

```
$ ./build.sh   # bundle install — passes
$ ./test.sh    # bundle exec rspec — 49 examples, 0 failures
```

`bundle exec ruby -Ilib -e "require 'end_point_blank'"` loads cleanly and
`EndPointBlank::Commands::Http::TIMEOUT_OPTIONS` /
`EndPointBlank::Writers::DelayedWriter::MAX_QUEUE_SIZE` are inspectable at
the top level, confirming the constants are reachable as documented.

`rubocop` was also run for hygiene (not part of CI — `ci.yml` only runs
`./test.sh`, i.e. rspec). It reports 46 offenses across the 5 touched files
vs. 43 pre-existing on the same files before this change — the 3 new ones
are `Metrics/AbcSize`/`Metrics/MethodLength` on `start_threads`, whose body
is unchanged except swapping `@queue` for the new `queue` reader method; all
newly-added methods (`enqueue_one`, `drop_oldest_and_note`, `note_drop`,
`warn_dropped_items`, `log_warning`) were kept short enough to avoid adding
further offenses. None of this blocks CI.

## Files changed

- `lib/end_point_blank/commands/http.rb` — shared timeout constants/helper,
  applied to `Http.post`.
- `lib/end_point_blank/commands/generate_access_token.rb` — applies shared
  timeout options to its `Excon.post`.
- `lib/end_point_blank/commands/endpoint_update.rb` — applies shared timeout
  options to its `Excon.post`; fixed the broken `Excon::Error::Connection`
  rescue clause to `rescue Excon::Error` (now also catches `Timeout`).
- `lib/end_point_blank/writers/delayed_writer.rb` — bounded, drop-oldest,
  throttled-warning queue.
- `lib/end_point_blank/authorization.rb` — `require 'base64'` (incidental
  fix, needed for the Basic-auth path to work at all on Ruby 3.4, and
  required to exercise the `endpoint_update` timeout test end-to-end).
- `end_point_blank.gemspec`, `Gemfile.lock` — declare `base64` as an
  explicit dependency (Ruby 3.4 removed it from default gems).
- New specs: `spec/commands_http_spec.rb`, `spec/generate_access_token_spec.rb`,
  `spec/endpoint_update_spec.rb`, `spec/delayed_writer_spec.rb`.

## Concerns / follow-ups (not fixed here, out of scope for P2 #14)

- The queue bound is a soft/approximate guarantee under heavy concurrent
  enqueue: the mutex only guards the *decision* to drop before push, so with
  many producer threads racing, the queue could very briefly be examined by
  more than one thread between the `pop`/`push` pair in rare interleavings
  is prevented by the mutex — but a concurrent **drain** thread popping at
  the same moment only ever shrinks the queue, never grows it past the cap.
  In practice the bound holds exactly given the mutex around all enqueue-side
  mutation.
- `note_drop`/`@last_drop_warning_at` state lives on the writer singleton
  instance (`RequestWriter`, `ResponseWriter`, `ExceptionWriter`,
  `LogWriter` each get their own independent throttle window since they each
  `include DelayedWriter` separately) — this is intentional (matches
  per-queue behavior) but worth knowing if someone expects a single global
  throttle across all four queues.
- Rubocop was not run as part of CI before this change and still isn't;
  pre-existing style debt (43 offenses) was left alone except where it was
  directly in code I touched and cheap to avoid growing.
