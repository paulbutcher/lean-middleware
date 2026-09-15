/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import Middleware.Core
public import Middleware.HeaderValue

public section

open Std.Http
open Std.Http.Server

namespace Middleware.Header.Name

def cacheControl : Header.Name := .mk "cache-control"
def vary : Header.Name := .mk "vary"
def expires : Header.Name := .mk "expires"

end Middleware.Header.Name

namespace Middleware

/--
How long a stored response may be reused before the client has to ask again (RFC 9111 §5.2).

`maxAge` suits a response whose URL changes whenever its content does; anything served under a
stable URL wants `noCache`, which still permits a stored copy and still earns a `304`, but never
lets the client skip the question. `shared` picks `public` over `private`.
-/
inductive CachePolicy where
  | noStore
  | noCache
  | maxAge (seconds : Nat) (shared : Bool := true) (immutable : Bool := false)

def CachePolicy.toWire : CachePolicy → String
  | .noStore => "no-store"
  | .noCache => "no-cache"
  | .maxAge seconds shared immutable =>
    (if shared then "public" else "private")
      ++ s!", max-age={seconds}"
      ++ (if immutable then ", immutable" else "")

/--
Sets `Cache-Control` on any response that doesn't already carry one, so a handler that chose its
own policy keeps it.

A response carrying an `ETag` or `Last-Modified` and no freshness directive is left to heuristic
freshness (RFC 9111 §4.2.2), which browsers take as a fraction of the age since `Last-Modified`:
a file untouched for a fortnight is reused for about a day without any request at all, so
`notModified` is never consulted and a redeployed asset stays stale in the browser.
-/
def cacheControl (policy : CachePolicy := .noCache) : Middleware :=
  fun handler =>
    { handler with
      onRequest := fun req => do
        let resp ← handler.onRequest req
        if resp.line.headers.contains Header.Name.cacheControl then
          pure resp
        else
          pure { resp with
            line := { resp.line with
              headers := resp.line.headers.insert Header.Name.cacheControl
                (Header.Value.ofStringSanitized policy.toWire) } } }

end Middleware
