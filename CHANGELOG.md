# Changelog

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
