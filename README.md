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
import MiddlewareCookieStore

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
     antiForgery { safeHeader := some (Std.Http.Header.Name.mk "X-Lean-Anti-Forgery") },
     contentType "application/octet-stream",
     defaultCharset "utf-8",
     notModified,
     file "public"]
    myApp
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
  in-process table, and `CookieStore` (`cookiestore/MiddlewareCookieStore.lean`, in a separate
  package -- see below), which keeps no server-side state at all: the session is AES-256-GCM
  sealed and the sealed blob itself is the cookie's value.
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

## Packages

The repository holds three Lake packages, split so that an application pays only for what it
uses. Lake resolves a package's requirements transitively and applies `moreLinkArgs` and
`extern_lib` per *package* to every executable linked against it, regardless of which modules
were imported -- so anything a shipping package declares becomes every client's problem.

- **`middleware`** (repository root): everything documented above, pure Lean. **No dependencies
  at all**, Lake or native.
- **`middleware-cookiestore`** (`cookiestore/`): `CookieStore` alone, which links OpenSSL's
  `libcrypto` via FFI (`cookiestore/MiddlewareCookieStore/AesGcm.lean`, `cookiestore/c/aesgcm.c`)
  for AES-256-GCM. Requires only `middleware`.
- **`middleware-tests`** (`test/`): the whole test suite, and the only package that depends on
  `Plausible`. Nothing ships it.

Applications that want `CookieStore` require both shipping packages:

```lean
require middleware from git "https://github.com/..." @ "main"
require «middleware-cookiestore» from git "https://github.com/..." @ "main" / "cookiestore"
```

and `import MiddlewareCookieStore`. The module root differs from the others because Lake resolves
each module name to exactly one package and the `Middleware.*` module tree belongs to
`middleware`; the Lean namespaces are unchanged, so the type is still `Middleware.CookieStore`.

## Formal verification

- **Path traversal** (`test/Tests/File.lean`): `File.joinSafeSegments` succeeds exactly when every
  segment is safe, and then returns exactly their `/`-intercalation, so a resolved path can never
  escape the served root or gain a component that wasn't a segment of its own.
- **Multipart splitting** (`test/Tests/Multipart.lean`): `Multipart.findAllOccurrences` reports
  exactly the in-bounds positions where the delimiter really occurs, so `splitParts` can neither
  cut a part at a false delimiter nor merge two parts by missing a real one.
- **Session data** (`test/Tests/Session.lean`): reads see the last write to that key, writing one key
  never disturbs another (so `flash` and `antiForgery`'s reserved keys coexist with an
  application's own), and rewriting a key replaces rather than accumulates (so a `CookieStore`
  session can't grow without bound).
- **Stack composition** (`test/Tests/Core.lean`): `Middleware.apply` distributes over list append and
  is unaffected by `Middleware.id`, so a stack can be split, regrouped, or have unused layers
  dropped without changing what the rest of it means.
- **ETag comparison** (`test/Tests/NotModified.lean`): weak comparison turns only on the opaque tag,
  and a tag listed anywhere in `If-None-Match` matches (RFC 9110 §8.8.3.2).

## Testing

`lake test` from the repository root runs the whole suite, which lives in `test/Tests/`:
example-based tests per middleware, `Plausible` property tests where an invariant is worth
checking but out of proportion to prove (Base64 and cookie-value round-trips, the `CookieStore`
wire format), and `test/Tests/Integration.lean` for behavior that only shows up once multiple
middlewares run together. It can also be run directly with `lake test` from `test/`.
