# Changelog

## [0.5.0] - 2026-08-18

More consistent port handling.

## [0.4.0] - 2026-08-18

`serverSpan`: OpenTelemetry `server` span around every request.

## [0.3.0] - 2026-08-15

- `CookieStore` moved into its own `middleware-cookiestore` package, so only applications that
  use it need OpenSSL to build.
- The test suite moved into its own `middleware-tests` package, so `Plausible` is no longer a
  dependency of anything shipped.

## [0.2.0] - 2026-08-11

A somewhat complete collection of middleware.

## [0.1.0] - 2026-08-11

Initial release.
