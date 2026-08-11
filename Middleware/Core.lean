/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Std.Http.Server

open Std.Http
open Std.Http.Server

/--
A function that wraps a `StatelessHandler`, adding behavior before and/or after the wrapped
handler runs. Composes via ordinary function composition.
-/
abbrev Middleware := StatelessHandler → StatelessHandler

namespace Middleware

/-- Leaves the handler unchanged. -/
def id : Middleware := fun handler => handler

/--
Applies a stack of middleware to a base handler. The first element of `mws` becomes the
outermost layer, closest to the client; the last element sits closest to `base`. A request
passes through the list head-first; the response flows back tail-first.

## Recommended order

Most applications using every middleware in this library should order them:

```
Middleware.apply
  [forwardedScheme, forwardedRemoteAddr,
   hsts, xFrameOptions, xContentTypeOptions, xXssProtection,
   catchAll,
   sslRedirect,
   cookies, session store, flash,
   params, multipartParams, antiForgery,
   absoluteRedirects,
   contentType, defaultCharset,
   notModified] (file root base)
```

Each position follows from a dependency one of the middlewares actually has, not from
convention:

- `forwardedScheme`/`forwardedRemoteAddr` outermost of everything: nothing else can use
  proxy-trusted request info before it's established, and establishing it can't itself fail, so
  there's no reason to nest it inside anything else.
- `hsts`/`xFrameOptions`/`xContentTypeOptions`/`xXssProtection` outside `catchAll`, deliberately,
  so they still apply to a `500` response. If they sat inside `catchAll`, an error response would
  ship with none of them.
- `catchAll` next, so it sees a failure from *any* layer below it and can turn it into a clean
  `500` instead of the connection tearing down. If it sat anywhere else, an exception thrown
  above it would go uncaught.
- `sslRedirect` outside `cookies`/`session`: no point running cookie or session logic against a
  request that's about to be redirected away from entirely.
- `cookies` next, before anything that reads or writes cookies. It's the only layer that turns
  a `SetCookies` accumulator into actual `Set-Cookie` wire headers, and the only one that parses
  the incoming `Cookie` header into the `Cookies` extension other middleware read.
- `session` right after `cookies`, since it reads its session-id cookie from the `Cookies`
  extension `cookies` attaches, and needs `cookies` outside it for its own contributed
  `Set-Cookie` (via `appendSetCookie`) to actually reach the client.
- `flash` right after `session`, since flash data lives inside the session (a reserved key in
  `SessionData`/`SessionUpdate`) and has nothing to read or write without it.
- `params`/`multipartParams` next -- request-body parsing, independent of the cookie/session
  layers above and of each other (they check disjoint `Content-Type`s and no-op otherwise, so
  using both together is safe if an application needs to accept either).
- `antiForgery` right after `params`/`multipartParams`, since it reads a submitted token out of
  whichever of those two extensions is present, and before the application handler so it can
  short-circuit a request carrying a missing or wrong token without the handler ever running.
- `absoluteRedirects` needs to see the real response's `Location` header, so it wraps everything
  that might produce a redirect -- typically the application handler itself.
- `contentType` and `notModified` must each wrap whatever actually produces the response body
  (typically `file`, or the application's own handler) -- both inspect headers on the *real*
  response (`Content-Type` presence, `ETag`/`Last-Modified`), which don't exist until that inner
  layer runs. `defaultCharset` sits right outside `contentType`, finishing off whatever
  `Content-Type` that middleware (or the handler) set.
- `file` (or the application's own router) innermost: it falls through to whatever's inside it
  when a request path doesn't match a real file, so it needs to be the last thing before the
  application's own logic, not the first.

An application that only uses some of these middlewares can drop the rest from the list; the
relative order among what's left still holds.
-/
def apply (mws : List Middleware) (base : StatelessHandler) : StatelessHandler :=
  mws.foldr (fun mw acc => mw acc) base

end Middleware
