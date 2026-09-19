# Changelog

## 0.11.1

### Fixed

- **`EndPointBlank.configure` is now all-or-nothing.** The sc-970 review
  found that this SDK (along with Java) applied a `configure` block's
  assignments to the live `Configuration` singleton as the block executed,
  so a field set *before* a later one failed validation stayed applied even
  though the whole call raised:

  ```ruby
  EndPointBlank.configure do |c|
    c.app_name = "checkout"  # applied immediately
    c.cache_ttl = -1         # raises ArgumentError here
  end
  # app_name was left as "checkout" -- half-updated, with no error saying so
  ```

  `configure` now yields a detached copy of the configuration, and once the
  block returns normally, writes back only the fields whose value on that
  copy differs from an independent deep copy taken before the block ran --
  so a rejected call leaves the live configuration exactly as it was,
  including a field set for the very first time (e.g. `client_id` on a
  fresh boot, before anything has ever assigned it) and an in-place edit
  anywhere in a String, Array or Hash field (both `masking_rules` and the
  rule Hashes in it, and a String field such as `app_name` edited with
  `<<`, are deep-copied into the block's copy). This holds for *any*
  exception the block raises, not only `StandardError`. Committing only
  what the block changed, rather than every field, also means a write to a
  field the block never touched -- made from inside the block itself (e.g.
  `EndPointBlank.logger =`) or concurrently from another thread outside
  `configure` -- is no longer silently reset back to what it was when the
  copy was made.

  `configure` calls are also now serialized with a Mutex held across the
  block and the commit, so two calls can no longer overlap. Without that,
  two calls that both succeed could still overlap -- the second starting
  while the first is still running -- and both would build their copy from
  the same starting snapshot. Whichever finished last would still decide
  what to write by comparing its own copy against that same now-stale
  snapshot rather than against whatever was live on `Configuration` by the
  time it actually committed, so it would silently write its own change
  over whatever the other call had already committed. Because Ruby's
  `Mutex` is not reentrant, calling `configure` again from inside a
  `configure` block, on the same thread, now raises `EndPointBlank::Error`
  instead of running -- previously, with no atomicity in place at all,
  nesting worked by accident, since both calls just mutated the live
  singleton directly. A block that starts a different thread, has it call
  `configure`, and then joins it will hang instead of raising, since that
  thread is genuinely waiting on a lock this thread holds.

  The copy `configure` yields (`c`, by convention) is only valid for the
  duration of the block: once `configure` returns, whether the block
  returned normally or raised, `c` is frozen, so a write made through a
  reference to it retained past the block raises `FrozenError` instead of
  silently going nowhere. Every field that gets committed is also now
  written as a fresh copy, not `c`'s own object, so the live
  `Configuration` never ends up aliasing anything `c` still holds -- that
  closes the one case freezing `c` itself doesn't cover: appending to an
  Array or Hash field it holds (e.g. `saved.masking_rules << rule` after
  the block) previously reached the live value directly once that field
  had been committed, since the candidate and the live config ended up
  holding the very same object, bypassing the Mutex and any validation
  with no error. A read that bypasses `c` -- `Configuration.instance.app_name`,
  or `EndPointBlank.logger` right after `c.logger = ...` earlier in the
  same block -- still sees the value from before the call started, not
  what the block has set on `c` so far, until the block returns and the
  commit runs.

  This is generic over every `Configuration` instance variable, not a
  hand-maintained field list, so a future validated field (e.g. sc-1265's
  planned `cache_ttl` upper bound) is atomic under `configure`
  automatically, with no changes needed here. Objects the caller hands in
  by reference -- `logger`, `mask_hook`, `version_finder` -- are copied by
  reference like any other field, not deep-copied, since they are not
  String/Array/Hash; `configure` cannot roll back mutation the caller
  performs on those objects themselves, and calling `configure` from more
  than one thread only serializes calls to `configure` itself, not reads of
  `Configuration` elsewhere.

  This is sc-1266. Of the other four EndPointBlank SDKs, only Java (`java#39`)
  had this bug and needed a code fix; JS, Python and Elixir were already
  atomic and got test-only PRs pinning that behavior.

## 0.11.0

### Breaking

- **`cache_ttl` is validated when you set it, not when the cache first uses
  it.** `c.cache_ttl =` now accepts only a non-negative `Integer` number of
  seconds. Anything else raises `ArgumentError`, naming `cache_ttl` and the
  value, from the assignment itself -- inside `EndPointBlank.configure`, so a
  bad value stops the app at boot -- and leaves the previous value in place.
  This is the rule sc-970 sets for every EndPointBlank SDK:

  | `cache_ttl` | 0.10.0 | Now |
  |---|---|---|
  | never set | 300 seconds | 300 seconds (unchanged) |
  | `0` | accepted: cache disabled | accepted: cache disabled (unchanged) |
  | `nil` | accepted; `TypeError: can't convert NilClass into an exact number` on the first cache store | `ArgumentError` at configure time |
  | negative, e.g. `-5` | accepted, silently behaving like `0` | `ArgumentError` at configure time |
  | a `String`, e.g. `"abc"` | accepted; `TypeError: can't convert String into an exact number` on the first cache store | `ArgumentError` at configure time |
  | a non-`Integer` number, e.g. `3.5` | accepted, silently used as a 3.5-second TTL | `ArgumentError` at configure time |

  **If you disabled the cache with a negative value such as `-1`, change it
  to `0`.** To get the default, omit the setting: no value assigned to
  `cache_ttl` means "use the default".

### Fixed

- **Runtime `cache_ttl` changes now apply to already-cached entries.**
  `AuthenticationCache` used to fix an entry's expiry once, at the moment it
  was stored; changing `cache_ttl` afterwards (typically to lower it during
  an incident, hoping to make a revocation take effect sooner) did nothing to
  entries already in the cache -- they kept answering until their *original*
  expiry, on the *old* TTL. Setting `cache_ttl` to a disabling value (`<= 0`)
  did nothing at all: it neither stopped new reads from being served nor
  removed what was already cached.

  Each entry now records its write time as well as its expiry, and every
  read re-derives validity against the `cache_ttl` configured *at read time*,
  anchored to that write time: an entry HITs only while it is within both its
  original expiry (so raising `cache_ttl` never extends an entry already
  cached) and the current `cache_ttl` measured from when it was written (so
  lowering `cache_ttl` shortens an already-cached entry's life immediately,
  on its next read).

  A disabled `cache_ttl` now MISSes, and the moment a read *or a store*
  observes the cache disabled, the **entire cache is cleared** -- not just
  the entry being looked up or written. An earlier version of this fix
  deleted only the single key involved, which let a *different*,
  already-revoked key go on answering after `cache_ttl` was raised again.
  This matches the Elixir SDK's existing `AuthCache.clear/0` behavior on its
  disabled get/put path. A store made while the cache is disabled still
  inserts nothing itself, on top of clearing what was already there.

  **This cache is per Ruby process** -- a plain in-memory Hash, nothing
  shared like `Rails.cache` or Redis -- so each Puma or Unicorn worker, and
  every separate app instance, holds its own cache and its own view of
  `cache_ttl`. "The entire cache is cleared" means *that process's* cache
  only: disabling `cache_ttl` does not by itself reach any other worker or
  instance, and each one clears its own cache only once it has itself
  observed `cache_ttl` disabled and then handled an `Authorized` request
  (or a direct cache call) while disabled. A worker sitting idle, or one
  that hasn't yet picked up the new config, keeps answering from whatever
  it already cached until it does. Known residual, left unaddressed here
  rather than fixed: a disable followed by a re-enable with **no cache read
  or store in between** flushes nothing, because nothing ever observed the
  disabled state to trigger the clear; this release does not add
  configure-time flushing.

  A `nil` `cache_ttl` is never read as "disabled": it is refused when it is
  assigned -- see Breaking, above.

## 0.10.0

### Fixed

- **The send queue no longer drops duplicate payloads.** The drain took a batch
  off the front of the pending list and then removed it with `payloads -= list`.
  `Array#-` removes every element *equal to* one in the batch, not the ones
  actually sent: seven byte-identical payloads with a batch size of six meant
  six delivered and all seven gone. Nothing counted the loss, nothing logged it,
  and the queue drained normally, so it read as if nothing had happened.

  Equal payloads are ordinary rather than exotic. Payloads are hashes, and two
  requests to the same endpoint, from the same application, in the same
  environment differ only in high-cardinality fields; `sent_at` at millisecond
  precision is not a reliable discriminator at ingest volumes. Any genuinely
  duplicate pair lost a member every time it landed in an over-full batch.

  Batches are now cut by position — `each_slice(BATCH_SIZE)` over the pending
  list, with no removal step at all — which makes equality irrelevant rather
  than merely handled. The batch size (6) is a named constant instead of a
  `[0..5]` in the middle of the loop; the batching behaviour is otherwise
  unchanged.

- **The authenticate payload names the caller's IP `source_ip`.** It sent
  `ip_address`; intake reads `source_ip` and casts it into `source_ip_address`.
  intake ignores keys it does not cast, so nothing crashed and nothing was
  refused — `source_ip_address` was simply NULL on every authenticate row from a
  Rails application, and any per-source-IP question about authenticate traffic
  read as though there were no traffic.

  This was not a porting slip. This gem has always sent `ip_address`, and the
  JS, Python and Java ports copied it faithfully, so all four were wrong
  together until those three were fixed. `EndpointAuthorize`, on the next path
  over, has always sent `source_ip` correctly.

  Because intake never read the old key, this can only begin populating a column
  that has never held anything: no migration, and nothing to be compatible with.

## 0.9.0

### Fixed

- **One unreachable intake no longer ends telemetry for the life of the
  process.** `Commands::Http.post` returns `nil` once its three attempts are
  exhausted; `DirectWriter#write` passed that straight back; and the delayed
  writer's worker loop called `response.status` on it. The resulting
  `NoMethodError` escaped `loop do`, which is the whole body of the worker
  thread, so the thread died — and a dead worker is not a failed delivery, it is
  the end of delivery. Every payload enqueued afterwards sat in the queue until
  it was pushed out by the drop-oldest bound, and nothing said so, because a
  dead thread raises nothing and logs nothing. The trigger was the most ordinary
  event there is: the intake briefly unreachable.

  Every other telemetry drop in this gem costs one batch. This one cost all of
  them, from one transient failure, with no recovery short of restarting the
  host application.

- **A `nil` response is treated as the absence of an answer, not as a status.**
  There is nothing to compare `nil` against, so it is not compared. The batch is
  reported through `on_failure` — with `nil`, meaning *nothing answered* — and
  named in an `error` log line that says how many payloads went with it. A
  writer that implements neither callback is unaffected, as before.

### Changed

- **The worker loop now survives anything a delivery can throw.** The `nil`
  above is one defect of a shape that has now been fixed in a writer three
  times, so this release fixes the shape rather than the instance: every
  `StandardError` raised anywhere in an iteration is caught, logged, and
  followed by another iteration. `DirectWriter#write` calls
  `Authorization.header` before it calls the transport, which is a second
  unguarded path into the same loop; it is covered too, without having had to be
  enumerated.

  Recovering silently would only trade one silent failure for another, so it is
  not silent:

  - every recovered error is logged at `error` level through
    `EndPointBlank.logger`, with the exception class, its message, the top
    backtrace frame, and a **count of consecutive failures** — so a persistent
    fault reads as `consecutive failure 47`, not as forty-seven
    indistinguishable lines;
  - consecutive failures back off, `WORKER_BACKOFF_SECONDS` (0.1s) doubling to
    `MAX_WORKER_BACKOFF_SECONDS` (30s), so a permanently broken send path is a
    slow loud retry rather than a hot loop with a fan attached. The counter
    resets on the first clean pass.

  What is deliberately *not* caught is anything outside `StandardError` —
  `SystemExit`, `Interrupt`, `SignalException`, `NoMemoryError`. Those mean the
  process itself is going down or is already broken, and a fire-and-forget
  telemetry worker has no business arguing with that.

- **`worker_count` is documented as what it is.** The README described it as
  "currently unused by the delayed writer (which always spins up 2 threads);
  reserved". It has been honoured for some time: the pool is `worker_count`
  threads, and the hardcoded 2 survives only as the fallback used when it is set
  to `nil`.

### Unchanged

- No public API is removed or renamed. `on_success`/`on_failure` remain
  optional, and the only change to their contract is that `on_failure` can now
  receive `nil`, in the case where it previously could not be reached at all.

## 0.8.0

### Fixed

- **`EndPointBlank::Rails::Authenticated` works.** It could not have worked
  once: it called `EndPointBlank::Commands::EndpointAuthenticate`, a constant
  this gem has never defined, so every action of every controller including the
  concern raised `NameError` from its `before_action` — before authentication
  could succeed or fail. It now calls
  `EndPointBlank::Commands::BasicAuthenticate`, the command that was in the tree
  the whole time and that the JS, Java and Python SDKs each document their own
  authenticate command as a port of.

  It was implemented rather than removed because three other SDKs expose an
  authenticate path and all three name this gem as the original — Elixir has
  none, so sc-306's "four other SDKs" is three, but it is three of three. A
  missing one in Ruby is a gap, not a decision. No public constant is removed:
  `Commands::EndpointAuthenticate` never resolved, so nothing could have been
  depending on it, and no `Commands::EndpointAuthenticate` is being introduced
  either — that would have been a second command for a job this gem already had
  a command for, with `BasicAuthenticate` left dead beside it.

- **`Commands::BasicAuthenticate` works.** It built its `Authorization` header
  from `AuthorizationGenerate.generate` — a second constant this gem has never
  defined — so repairing only the concern's constant would have moved the same
  `NameError` one frame deeper. It now uses `Authorization.header`, as
  `EndpointAuthorize` and all three ports of this command do. Neither defect was
  reachable by any test or any application, which is how both survived a
  coverage pass: a file no spec requires and no application includes is
  invisible to a coverage number.

- **A nil answer from intake reaches the branch written for it.**
  `authenticate!` parsed the response body on the line *above* its own
  `if !result` guard, so a nil result died with `NoMethodError` on `nil.body`
  and the nil branch could never run. Fixed in the same pass rather than left to
  be uncovered by fixing the constant.

- **A refusal from `Authenticated` now says which refusal it was.** The concern
  used `raise UnauthorizedError, "message"` — the two-argument
  `raise Class, message` form, which calls `Class.exception(message)` and can
  pass nothing else, so it structurally could not carry intake's status however
  willing `UnauthorizedError` was to accept one. Every refusal would therefore
  have arrived as the class's 401 default, including the 403 that means
  `access_denied`. `Authorized` has always passed intake's status through, so
  the same denial gave a caller two different answers depending on which concern
  the controller included.

  401 and 403 send an integrator to two different places: *re-check the
  credential* versus *ask for a grant covering this endpoint*. Collapsing them
  sends half of them to debug the wrong thing.

  | intake answered | `error.status` | what it tells the integrator |
  | --- | --- | --- |
  | 401 | `401` | the credential was not accepted — re-check or re-issue it |
  | 403 | `403` | the credential is fine; no grant covers this endpoint |
  | any other non-201 | that status | intake's own verdict, verbatim |
  | nothing at all | `503` | the check could not be made; nothing judged this caller |

  The README's own suggested handler — `status: e.status` — was written as
  though this already worked, and on the `Authorized` path it did. It now works
  on both.

### Changed

- **An intake 5xx now reaches a caller of an `Authenticated` controller as that
  5xx**, where it would previously have reached them as a 401. An outage in
  intake presents as an outage rather than as a rejected credential, so a client
  branching on `401` to trigger a re-login will no longer do so for a fault that
  has nothing to do with its credential. The same is true of an unreachable
  intake, which is now a 503 — this is what `Authorized` has always answered for
  that case, and what all four other SDKs answer.

  In practice no deployment can have observed the old behaviour, because the
  concern raised `NameError` before reaching any of it. It is called out anyway
  because the other three SDKs called out exactly this change for exactly this
  reason, and because anyone reading their changelogs should find the Ruby entry
  saying the same thing.

- The two concerns' refusal handling — two transcriptions of one decision, which
  had drifted — is now one method,
  `EndPointBlank::UnauthorizedError.refusal_from(result, action)`. Two copies is
  how one path acquires a fix the other does not, which is precisely what
  happened here. `Authorized` behaves exactly as before: its refusal path moved
  into the shared method without changing the message or the status it produces
  for any input, including the unreachable case, whose message has never carried
  a `"Authorization failed:"` prefix and still does not.
- `Rails::Authorized#authorize_error_message`, a private method, is gone; its
  body is now the shared `refusal_from`.

### Unchanged

- `UnauthorizedError.new(message)` still means what it meant: the status
  defaults to 401, and the status remains the optional second argument. The
  class itself is otherwise untouched — it always accepted a status, which is
  why nothing ever complained that `authenticate!` was not passing one.
- `Authenticated` deliberately does **not** cache intake's answer, matching every
  other SDK's authenticate command. `Authorized` caches as before.

## 0.7.0

### Added

- **You can now tell a rejected credential from a server that is merely
  having a bad day.** intake answers `401` when the API credential itself is
  refused and something else for everything else, but the SDK threw the status
  away: `Commands::GenerateAccessToken.token` returned the parsed body no
  matter what came back, and `AccessTokens#token` turned every failure into
  the same `nil` and the same `"Failed to generate access token"` log line. A
  revoked credential and a transient 503 were indistinguishable, so nothing
  could decide whether to retry or to stop and ask a human.

  Two additive entry points:

  - `Commands::GenerateAccessToken.token_result(base_url)` returns an
    immutable `Commands::AccessTokenResult` carrying `outcome`, `status` and
    `payload`, with `#success?`, `#credential_rejected?`, `#request_rejected?`,
    `#server_error?`, `#transport_error?` and `#failure?`.
  - `EndPointBlank::AccessTokens.last_failure(base_url)` (and the instance
    method) returns an `AccessTokens::Failure` — `base_url`, `outcome`,
    `status`, `reason`, `at`, and the same predicates — describing why the
    last mint for that URL failed, or `nil` when the last one succeeded.

  ```ruby
  result = EndPointBlank::Commands::GenerateAccessToken.token_result("https://api.example.com/orders")
  result.credential_rejected? # => true; re-issue the credential, retrying will not help
  result.status               # => 401

  EndPointBlank::AccessTokens.token("https://api.example.com/orders") # => nil, as before
  EndPointBlank::AccessTokens.last_failure("https://api.example.com/orders").status # => 401
  ```

  The five outcomes are `:success` (a token really was minted: a 2xx whose
  body parsed and carries a non-empty `token` and the non-empty `base_url` to
  cache it under), `:credential_rejected` (401), `:request_rejected` (any
  other 4xx), `:server_error` (5xx, any other unexpected non-2xx, and a 2xx
  that carried nothing usable) and `:transport_error` (no usable HTTP status
  was obtained at all).

  `#success?` is worth reading precisely: it is true only when there is a
  token on the payload to read, so a caller that branches on it never has to
  check for one again. A success predicate that can be true while the token is
  absent makes every caller re-check the payload by hand, and that is the
  check that gets forgotten.

  There is deliberately **no** `#retriable?` or equivalent retry/no-retry
  boolean. intake answers `400` for an invalid `token_ttl` or a missing
  `base_url` and `422` for an unresolvable target/source application; those
  are as permanent as a 401, with a different remedy, and folding five honest
  names back into one boolean is a smaller version of the bug this release
  fixes. Branch on the outcome you can see.

- **Classification is on the HTTP status first, the body second.** A `401`
  whose body will not parse is still `:credential_rejected` — the SDK reaches
  intake through a proxy, and a WAF or load balancer can answer 401 with an
  HTML page intake never generated. `:transport_error` means one thing only:
  no usable HTTP status was obtained.

- A rejected credential now gets its own loud log line naming the remedy,
  instead of scrolling past as the same generic failure as a network blip.

### Changed

- A response that carries a token and a `base_url` is cached only when it
  arrived with a 2xx status. Previously any status would do, so a 4xx that
  echoed a token back would have been cached. A 2xx that carried no token, or
  a token with no `base_url` to key it under, is now reported as a
  `:server_error` with its real 2xx status attached; the specific reason
  ("no token in response", "response carried a token but no base_url") still
  appears in the log line, exactly as before.
- An **empty** `token` or `base_url` counts as a missing one. `""` is truthy
  in Ruby, so a plain presence check called such a response a success and
  handed the caller an empty bearer token to send, or cached a token under a
  key no lookup could ever match. Both are now `:server_error` with the real
  2xx status, and the value must be a non-empty String — an array or an object
  where a token belongs is a broken server too.
- The parsed body is still attached to the result when an unusable 2xx is
  classified `:server_error`, so `Commands::GenerateAccessToken.token` — the
  published payload-or-`nil` accessor — hands back exactly the body it always
  did for such a response.
- A response body that will not parse is logged as an error rather than
  silently becoming `nil`. It is still classified by the status that carried
  it, never as a transport error: unreadable under a 2xx is a `:server_error`,
  unreadable under a 401 is still `:credential_rejected`.
- `AccessTokens#clear` also drops the recorded failures.

### Changed

- **`Commands::GenerateAccessToken.token` now returns `nil` unless a token was
  actually minted.** It previously returned the symbol-keyed body of any status
  it could read — an `error` document from a 401 or 422, or a 2xx that parsed
  into something with no usable token in it. Each of those handed the caller a
  truthy value for a request that produced no token, which is the failure
  `token_result` was added to remove, one layer down.

  This aligns all five SDKs with Elixir, whose equivalent has always answered
  nil for anything that was not a mint.

  **Upgrade note:** nothing in this gem calls `token` — `AccessTokens` reads
  `token_result(base_url).payload` — so no log line or diagnostic changes. A
  caller that read an error out of the return value should call `token_result`
  instead: `.payload` is exactly what `token` used to hand back, now alongside
  the outcome that explains it. A caller that only ever read `[:token]` needs
  no change, because a body without a usable token was never something it
  could act on.

### Compatibility

- `AccessTokens#token` still returns a token String or `nil`, and `#exists?`
  still returns a Boolean.

## 0.6.1

### Fixed

- **Diagnostics now go to stderr, not stdout.** `EndPointBlank.logger` defaulted
  to `Logger.new($stdout)`. This gem runs inside your process, so everything it
  logged landed in your application's own output — which corrupts any program
  whose stdout carries structured data, such as a CLI emitting JSON or a worker
  writing a protocol stream, with no way for you to separate the two.

  If you were relying on SDK log lines appearing on stdout, they now appear on
  stderr. `EndPointBlank.logger=` still overrides, unchanged.

## 0.6.0

### Breaking

- **`Authorization.header` and `AccessTokens.token` now take a URL, not a
  hostname.** Pass the URL you are about to call —
  `https://api.example.com/orders`, not `api.example.com`. Strip any query
  string or fragment first; they are rejected. Earlier READMEs showed the
  hostname form; those examples no longer work.
- **`AccessTokens#exists?` now requires the same URL argument.** It answers
  for the entry covering that URL; there is no longer a single process-wide
  token for it to answer about.
- **Requires an intake that accepts `base_url`.** An older intake returns
  `400 {"error":"Missing required parameter: base_url"}`.

### Changed

- `endpoint_authorize` authenticates to intake with Basic instead of minting
  an access token for itself. The inbound request path no longer touches the
  token cache at all.
- A 401 from the authorize endpoint is returned to the caller rather than
  retried once. With Basic, a 401 means the credential is wrong.
- Tokens are cached per application environment, keyed on the canonical base
  URL intake resolves the request to, rather than one per process.

### Security

- The minted bearer token was previously written to the host application's
  logs at info level: every successful token exchange logged the full intake
  response body, which contains the live token, whenever your app's Rails
  logger was set to info or more verbose. This release logs only the
  response status code. If your logs go back further than this upgrade,
  treat them as potentially containing live bearer tokens and handle them
  per your own retention/rotation policy.
