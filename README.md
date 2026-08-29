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
import MiddlewareTracing

open Middleware

def myApp : StatelessHandler := { onRequest := fun _ => Response.ok |>.text "hello" }

def buildSecureSiteServer (sessionStore : CookieStore)
    (matchedRoute : Extensions → Option String) : StatelessHandler :=
  Middleware.apply
    [forwardedScheme Middleware.Header.Name.xForwardedProto,
     forwardedRemoteAddr Middleware.Header.Name.xForwardedFor,
     hsts, 
     xFrameOptions .sameOrigin, xContentTypeOptions,
     catchAll,
     serverSpan matchedRoute {},
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
- `serverSpan` (`tracing/MiddlewareTracing.lean`): opens an OpenTelemetry `server` span around
  every request.
- `antiForgery` (`Middleware/AntiForgery.lean`): CSRF protection via a session-backed
  synchronizer token, checked against a submitted form field, `X-CSRF-Token`, or `X-XSRF-Token` on
  any non-safe request. Requires `session` wrapped outer.

### Requiring an extension

A handler reading `(req.extensions.get Params).bind (·.get "title")` gets `none` both when the
form was empty and when `params` was never in the stack. The second is a misconfigured server,
and it goes unreported.

`withParams` (`Middleware/Extensions.lean`) hands the parameters to the handler instead, and
refuses the request with a `500` when nothing established them:

```lean
def create : StatelessHandler :=
  { onRequest := withParams fun ps _ =>
      match ps.get "title" with
      | some title => Response.ok.text title
      | none => Response.badRequest.text "title is required" }
```

`withSession`, `withToken`, `withFlash` and `withCookies` do the same for the other extensions
their middleware insert unconditionally, and `requiring` is the general form they are all
specialisations of. `MultipartParams`, `ForwardedFor` and `Scheme` are inserted only when the
request warrants one, so absence there says nothing about the stack and they get no helper.

Pass `missing` to answer with something other than the default `500`:
`withParams (missing := myErrorPage) fun ps req => ...`.

These are handler combinators, not middleware; they wrap the innermost handler rather than
appearing in `apply`'s list.

## Tracing

`serverSpan` opens an OpenTelemetry `server` span around every request and publishes its
`SpanContext` into the request's extensions:

```lean
open Telemetry

def loadUser (req : Request Body.Stream) (id : String) : TelemetryT IO User :=
  withSpanContext (parentSpan req) do
    spanning "db.query" (attrs := [(Conventions.dbOperationName, "SELECT")]) do
      ...
```

`ServerSpanOptions` adds `client.address`, `user_agent.original` and, opt-in because a query
string can carry credentials, `url.query`. Its `skip` predicate drops a request from tracing
altogether, which is worth pointing at static assets to avoid every asset `file` serves
becoming its own export.

## Testing

`Middleware.Test.Browser` (`Middleware/Test/Browser.lean`) drives a stack across several
requests the way a browser does, carrying a cookie jar between them:

```lean
open Middleware.Test

def signUpThenSeeGreeting : IO Unit := do
  let browser ← Browser.new (app store).onRequest
  let _ ← browser.post "/sign-up" [("email", "a@example.com")] .omitted
  assertContains (← browser.get "/") "Welcome back"
```

`get` sends the jar's cookies and harvests every `Set-Cookie` back into it, so a session, a
flash message, or a login stays in force from one request to the next. `post` form-encodes its
fields and sends the jar too.

A stack containing `antiForgery` needs one thing more, since it refuses any post not carrying a
token from the session. `get` also scrapes the token out of the page it fetched, and `post`
sends it, as a form field or (with `.header`) as `X-CSRF-Token`:

```lean
  let _ ← browser.get "/articles/new"
  let response ← browser.post "/articles" [("title", "Hello")]
```

A page that stops rendering its token fails the test, which is the point of scraping it rather
than reading it from the session store. `post` throws rather than sending no token at all, so a
`403` can never be misread as a pass; `.omitted`, above, is how a stack with no `antiForgery`
says it has none to send.

The default scrapes the hidden field, `name="..." value="..."`. A page carrying its token in an
HTML attribute instead needs its own `tokenFrom`, because an attribute's value is escaped and
the token inside it is delimited by `&quot;` rather than by `"`. `tokenBetween` takes both ends,
so the HTMX idiom, `hx-headers` carrying `{"X-CSRF-Token": "..."}`, is one line:

```lean
  let browser ← Browser.new (app store).onRequest
    (tokenFrom := tokenBetween "X-CSRF-Token&quot;: &quot;" "&quot;")
```

It is not imported by `Middleware`, since it pulls in `Std.Http.Test.Helpers`. Import
`Middleware.Test.Browser` from the test suite that wants it.

## Packages

- **`middleware`**: everything apart from `CookieStore` and `serverSpan`. Depends on nothing
  beyond Lean core and Std.
- **`middleware-cookiestore`**: `CookieStore` alone, which links OpenSSL's `libcrypto` via FFI.
- **`middleware-tracing`**: `serverSpan` alone, which needs `telemetry`.

Each is required separately, so an application pays for only what it uses:

```lean
require middleware from git "https://github.com/..." @ "main"
require «middleware-cookiestore» from git "https://github.com/..." @ "main" / "cookiestore"
require «middleware-tracing» from git "https://github.com/..." @ "main" / "tracing"
```

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
- **Token scraping** (`test/Tests/Browser.lean`): `Test.tokenBetween` returns exactly the text
  between the first occurrence of its marker and the next terminator, so a `Browser` posts back
  the token the page really rendered rather than a truncated or overrun reading of it.
