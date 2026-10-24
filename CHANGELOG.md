# Changelog

## [Unreleased]

- Every middleware is generic over `routing`'s `Engine`, so it runs on LeanIn as well as `Std.Http.Server`; write `Middleware .std` where `Middleware` was.
- `params` refuses a form body over `ParamsOptions.maxBodySize`, 1 MiB by default, with `413`, and one that is not UTF-8 with `400`.
- `multipartParams` refuses a body over `MultipartOptions.maxBodySize`, 16 MiB by default, with `413`.
- `file` and `assets` open a file only once its response is sent, so a response `notModified` replaces opens nothing.

## [0.17.1] - 2026-10-20

- Chore: bump dependencies

## [0.17.0] - 2026-10-18

- `extract` runs typed `Extractor`s in order, answering the request with the first refusal.
- `withParams`, `withSession`, `withToken`, `withFlash` and `withCookies` are gone; use `extract` with the matching `Extract` extractor.

## [0.16.0] - 2026-09-15

- `middleware-assets` serves files under a path carrying the SHA-256 digest of their content, so a far-future cache policy can never pin a stale copy.

## [0.15.0] - 2026-09-15

- `cacheControl` sets a `Cache-Control` freshness policy.
- A `304` from `notModified` carries the original response's `Cache-Control`, `Vary` and `Expires`.

## [0.14.0] - 2026-09-10

- `Middleware.Crypto.Base64` is gone; `CookieStore` encodes with `leancrypto`, whose base64 is proved to round-trip and refuses an encoding with bits set beyond the bytes it carries.
- `CookieStore` seals sessions through `lean-libcrypto` rather than a hand-written OpenSSL shim, so `Middleware.Crypto.aes256GcmSeal` and `aes256GcmOpen` now answer in `IO`.

## [0.13.0] - 2026-08-30

- `session` and `flash` refuse a stack missing the layer they require, naming it, rather than reading its absence as a request that carried no cookie and no message.
- Every theorem now carries a doc comment.

## [0.12.0] - 2026-08-29

- `Test.tokenBetween` takes a terminator, so a token delimited by an escaped `&quot;` scrapes correctly.
- `Browser.post` names which mistake left it with no token to send.

## [0.11.0] - 2026-08-28

`Middleware.Test.Browser`.

## [0.10.0] - 2026-08-28

- Allow middlewares to be required.
- `Params.get` now looks a parameter up by its decoded name.

## [0.9.0] - 2026-08-24

Fix a number of issues where invalid characters could find their way into headers and cookies.

## [0.8.0] - 2026-08-23

`catchAll` now reports the errors it recovers from to the handler's `onFailure`

## [0.7.0] - 2026-08-22

`Middleware.File.streamFile` is now total.

## [0.6.0] - 2026-08-20

Switch to module system.

## [0.5.0] - 2026-08-18

More consistent port handling.

## [0.4.0] - 2026-08-18

`serverSpan`: OpenTelemetry `server` span around every request.

## [0.3.0] - 2026-08-15

- `CookieStore` moved into its own `middleware-cookiestore` package, so only applications that use it need OpenSSL to build.
- The test suite moved into its own `middleware-tests` package, so `Plausible` is no longer a dependency of anything shipped.

## [0.2.0] - 2026-08-11

A somewhat complete collection of middleware.

## [0.1.0] - 2026-08-11

Initial release.
