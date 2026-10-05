/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import Middleware.Core
public import Middleware.HeaderValue
public import Middleware.CacheControl

public section

open Std.Http
open Std.Http.Server

namespace Middleware.Header.Name

def origin : Header.Name := .mk "origin"
def accessControlRequestMethod : Header.Name := .mk "access-control-request-method"
def accessControlRequestHeaders : Header.Name := .mk "access-control-request-headers"
def accessControlAllowOrigin : Header.Name := .mk "access-control-allow-origin"
def accessControlAllowMethods : Header.Name := .mk "access-control-allow-methods"
def accessControlAllowHeaders : Header.Name := .mk "access-control-allow-headers"
def accessControlAllowCredentials : Header.Name := .mk "access-control-allow-credentials"
def accessControlExposeHeaders : Header.Name := .mk "access-control-expose-headers"
def accessControlMaxAge : Header.Name := .mk "access-control-max-age"

end Middleware.Header.Name

namespace Middleware

/-- Which origins may read responses. `any` answers `*`, which browsers refuse to pair with
credentials, so `CorsOptions.credentials` is ignored under it. -/
inductive AllowedOrigins where
  | any
  | list (origins : List String)
  | matching (allowed : String → Bool)

def AllowedOrigins.allows : AllowedOrigins → String → Bool
  | .any, _ => true
  | .list origins, origin => origins.contains origin
  | .matching allowed, origin => allowed origin

/-- `allowHeaders := none` reflects whatever headers a preflight asks for. -/
structure CorsOptions where
  origins : AllowedOrigins := .any
  methods : List Method := [.get, .head, .post, .put, .patch, .delete]
  allowHeaders : Option (List String) := none
  exposeHeaders : List String := []
  credentials : Bool := false
  maxAge : Option Nat := some 600

private def set (name : Header.Name) (value : String) (headers : Headers) : Headers :=
  (headers.erase name).insert name (Header.Value.ofStringSanitized value)

/-- The headers every answer to an allowed origin carries. A response that depends on the origin
says so with `Vary`, or a shared cache would hand one origin's answer to another. -/
private def originHeaders (options : CorsOptions) (origin : String) (headers : Headers) : Headers :=
  match options.origins with
  | .any => set Header.Name.accessControlAllowOrigin "*" headers
  | _ =>
    let headers := set Header.Name.accessControlAllowOrigin origin headers
    if options.credentials then set Header.Name.accessControlAllowCredentials "true" headers
    else headers

private def withVary (options : CorsOptions) (headers : Headers) : Headers :=
  match options.origins with
  | .any => headers
  | _ => headers.insert Header.Name.vary (Header.Value.ofStringSanitized "Origin")

private def preflightHeaders (options : CorsOptions) (requested : Option String) (headers : Headers) :
    Headers :=
  let headers := set Header.Name.accessControlAllowMethods
    (", ".intercalate (options.methods.map toString)) headers
  let allowHeaders := match options.allowHeaders with
    | some names => some (", ".intercalate names)
    | none => requested
  let headers := match allowHeaders with
    | some names => if names.isEmpty then headers else set Header.Name.accessControlAllowHeaders names headers
    | none => headers
  match options.maxAge with
  | some seconds => set Header.Name.accessControlMaxAge (toString seconds) headers
  | none => headers

/-- Cross-origin resource sharing (the Fetch standard's CORS protocol).

A request without an `Origin` passes through untouched. A preflight, an `OPTIONS` naming the
method it will use in `Access-Control-Request-Method`, is answered here with `204` and never reaches
the handler. Any other request from an allowed origin reaches the handler and its response gains
the allow headers; one from an origin that is not allowed gains none, which is how a browser learns
to withhold it. -/
def cors (options : CorsOptions := {}) : Middleware :=
  fun handler =>
    { handler with
      onRequest := fun req => do
        let some origin := (req.line.headers.get? Header.Name.origin).map (·.value)
          | handler.onRequest req
        let allowed := options.origins.allows origin
        let isPreflight := req.line.method == .options &&
          (req.line.headers.get? Header.Name.accessControlRequestMethod).isSome
        if isPreflight then
          let requested := (req.line.headers.get? Header.Name.accessControlRequestHeaders).map (·.value)
          let headers := withVary options Headers.empty
          let headers := if allowed then preflightHeaders options requested (originHeaders options origin headers)
            else headers
          pure {
            line := { status := .noContent, version := req.line.version, headers },
            body := Body.Any.ofBody ({} : Body.Empty) }
        else
          let resp ← handler.onRequest req
          let headers := withVary options resp.line.headers
          let headers := if allowed then
              let headers := originHeaders options origin headers
              if options.exposeHeaders.isEmpty then headers
              else set Header.Name.accessControlExposeHeaders (", ".intercalate options.exposeHeaders) headers
            else headers
          pure { resp with line := { resp.line with headers } } }

end Middleware
