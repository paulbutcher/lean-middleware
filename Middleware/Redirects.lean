/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Middleware.Proxy

open Std.Http
open Std.Http.Server

namespace Middleware.Header.Name

def location : Header.Name := .mk "location"

end Middleware.Header.Name

namespace Middleware

/-- Options for `sslRedirect`. -/
structure SslRedirectOptions where
  /-- If set, overrides the port in the redirect's `Host` with this one. -/
  sslPort : Option Nat := none

/-- Redirects any request whose `Scheme` (see `forwardedScheme`) isn't `https` to the same
request-target over `https`, without calling the inner handler. Requests with no `Host` header,
or no `Scheme` extension at all, are also passed through untouched (nothing to build a redirect
target from; an absent `Scheme` is treated as `http`, per `requestOrigin`'s documented
safe-failure default, so it's only the missing-`Host` case that actually falls through here).
`GET`/`HEAD` get a cacheable `301`; anything else gets a `307`, which -- unlike `301`/`302` --
preserves the original method and body on the client's follow-up request. -/
def sslRedirect (options : SslRedirectOptions := {}) : Middleware :=
  fun handler =>
    { handler with
      onRequest := fun req => do
        match (req.extensions.get Scheme).getD .http with
        | .https => handler.onRequest req
        | .http =>
          match req.line.headers.get? Header.Name.host with
          | none => handler.onRequest req
          | some hostValue =>
            let host := match options.sslPort with
              | none => hostValue.value
              | some port => s!"{(hostValue.value.splitOn ":").headD hostValue.value}:{port}"
            let location := s!"https://{host}{toString req.line.uri}"
            let status :=
              if req.line.method == .get || req.line.method == .head then
                Status.movedPermanently
              else
                Status.temporaryRedirect
            let headers := Headers.empty.insert Header.Name.location (Header.Value.ofString! location)
            pure {
              line := { status, version := req.line.version, headers },
              body := Body.Any.ofBody ({} : Body.Empty) } }

/-- Rewrites a relative `Location` header on a redirect-shaped response (`201`, `301`, `302`,
`303`, `307`) to an absolute URL, using `requestOrigin`. Left alone if there's no `Location`, it's
already absolute, or there's no `Host` header to build an origin from. -/
def absoluteRedirects : Middleware :=
  fun handler =>
    { handler with
      onRequest := fun req => do
        let resp ← handler.onRequest req
        let isRedirectStatus :=
          match resp.line.status with
          | .created | .movedPermanently | .found | .seeOther | .temporaryRedirect => true
          | _ => false
        if !isRedirectStatus then
          pure resp
        else
          match resp.line.headers.get? Header.Name.location with
          | none => pure resp
          | some loc =>
            let lower := loc.value.toLower
            if lower.startsWith "http://" || lower.startsWith "https://" then
              pure resp
            else
              match requestOrigin req with
              | none => pure resp
              | some origin =>
                let absolute :=
                  if loc.value.startsWith "/" then s!"{origin}{loc.value}" else s!"{origin}/{loc.value}"
                let headers := (resp.line.headers.erase Header.Name.location).insert
                  Header.Name.location (Header.Value.ofString! absolute)
                pure { resp with line := { resp.line with headers } } }

end Middleware
