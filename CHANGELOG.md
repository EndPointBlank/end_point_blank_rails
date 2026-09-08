# Changelog

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

### Compatibility

- Nothing was removed or reshaped. `Commands::GenerateAccessToken.token`
  still returns the symbol-keyed body for any status it could read — 401 and
  422 included — and `nil` when it could not. `AccessTokens#token` still
  returns a token String or `nil`, and `#exists?` still returns a Boolean.

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
