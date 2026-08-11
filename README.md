# middleware

A middleware library for [`Std.Http.Server`](https://leanprover.github.io).

## Usage

See `Middleware.apply`'s doc comment (`Middleware/Core.lean`) for why the middlewares are
ordered as follows.

### An API

```lean
import Middleware

open Middleware

def myApi : StatelessHandler := { onRequest := fun _ => Response.ok |>.text "{}" }

def buildSecureApiServer : StatelessHandler :=
  Middleware.apply
    [forwardedScheme Middleware.Header.Name.xForwardedProto,
     forwardedRemoteAddr Middleware.Header.Name.xForwardedFor,
     hsts,
     catchAll,
     sslRedirect,
     params,
     contentType "application/octet-stream", 
     defaultCharset "utf-8",
     notModified]
    myApi
```

### A browser-facing site

```lean
import Middleware

open Middleware

def myApp : StatelessHandler := { onRequest := fun _ => Response.ok |>.text "hello" }

def buildSecureSiteServer (sessionStore : CookieStore) : StatelessHandler :=
  Middleware.apply
    [forwardedScheme Middleware.Header.Name.xForwardedProto,
     forwardedRemoteAddr Middleware.Header.Name.xForwardedFor,
     hsts, 
     xFrameOptions .sameOrigin, xContentTypeOptions,
     catchAll,
     sslRedirect,
     cookies,
     session sessionStore
       { cookieName := "secure-ring-session",
         cookieAttrs := { path := some "/", httpOnly := true, secure := true } },
     flash,
     params, 
     multipartParams,
     antiForgery { safeHeader := some (Std.Http.Header.Name.mk "X-Ring-Anti-Forgery") },
     contentType "application/octet-stream",
     defaultCharset "utf-8",
     notModified]
    (file "public" myApp)
```

## Middlewares

A `Middleware` wraps a `StatelessHandler`, adding behavior before and/or after the wrapped
handler runs (`Middleware/Core.lean`). A stack of middleware composes via `Middleware.apply`,
outermost-first.

- `catchAll` (`Middleware/CatchAll.lean`): turns an uncaught exception into a `500` response
  instead of tearing down the connection.
- `cookies` (`Middleware/Cookies.lean`): parses the `Cookie` request header and writes
  `Set-Cookie` response headers, with full RFC 6265 attribute support (`Path`, `Domain`,
  `Max-Age`, `Expires`, `Secure`, `HttpOnly`, `SameSite`).
- `session` (`Middleware/Session.lean`): server-side sessions keyed by a cookie, backed by a
  pluggable `SessionStore` typeclass. Two implementations are included: `MemoryStore`, an
  in-process table, and `CookieStore` (`Middleware/CookieStore.lean`), which keeps no server-side
  state at all: the session is AES-256-GCM sealed and the sealed blob itself is the cookie's
  value.
- `flash` (`Middleware/Flash.lean`): one-request-lifetime flash messages, layered on `session`.
- `params` (`Middleware/Params.lean`): attaches query-string and
  `application/x-www-form-urlencoded` body parameters as a `Params` extension.
- `multipartParams` (`Middleware/Multipart.lean`): parses `multipart/form-data` bodies (file
  uploads and mixed form fields), with size limits and size-threshold spooling to temp files.
- `contentType` (`Middleware/ContentType.lean`): infers a `Content-Type` response header from
  the request path's file extension, when the handler hasn't already set one.
- `notModified` (`Middleware/NotModified.lean`): downgrades a response to `304 Not Modified`
  based on `If-None-Match`/`If-Modified-Since` against the response's own `ETag`/`Last-Modified`.
- `file` (`Middleware/File.lean`): serves static files from a root directory, with
  path-traversal protection, falling through to the wrapped handler for anything that isn't a
  real file under that root.
- `xFrameOptions`, `xContentTypeOptions`, `xXssProtection`, `hsts`
  (`Middleware/Security.lean`): static browser-security response headers
  (`X-Frame-Options`, `X-Content-Type-Options: nosniff`, `X-XSS-Protection`,
  `Strict-Transport-Security`).
- `defaultCharset` (`Middleware/Charset.lean`): appends `; charset=...` to a text-based
  `Content-Type` that doesn't already declare one.
- `forwardedScheme`, `forwardedRemoteAddr` (`Middleware/Proxy.lean`): trust
  `X-Forwarded-Proto`/`X-Forwarded-For` from a reverse proxy, since `Std.Http.Server` has no
  built-in TLS support and so no native notion of request scheme at all.
- `sslRedirect`, `absoluteRedirects` (`Middleware/Redirects.lean`): redirect `http` requests to
  `https` (per `forwardedScheme`), and rewrite relative `Location` headers on redirect responses
  to absolute ones.
- `antiForgery` (`Middleware/AntiForgery.lean`): CSRF protection via a session-backed
  synchronizer token, checked against a submitted form field, `X-CSRF-Token`, or `X-XSRF-Token` on
  any non-safe request. Requires `session` wrapped outer.

## Native dependency

Everything in this library is pure Lean except `CookieStore`, which links OpenSSL's `libcrypto`
via FFI (`Middleware/Crypto/AesGcm.lean`, `c/aesgcm.cpp`) for AES-256-GCM.

## Testing

`lake test` runs the full suite: example-based tests per middleware, `Plausible` property tests
where a genuine invariant exists (round-trips, non-clobbering, weak-match logic), and
`Tests/Integration.lean` for behavior that only shows up once multiple middlewares run together.
