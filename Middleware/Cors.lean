/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import Middleware.Core
public import Middleware.HeaderValue

public section

open Std.Http
open Routing

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
def secFetchSite : Header.Name := .mk "sec-fetch-site"

end Middleware.Header.Name

namespace Middleware

variable {e : Engine}

/-- Which origins may read responses. `any` answers `*`, which browsers refuse to pair with
credentials, so only the constructors that echo an origin can allow them. -/
inductive AllowedOrigins where
  | any
  | list (origins : List String) (credentials : Bool := false)
  | matching (allowed : String → Bool) (credentials : Bool := false)

/-- Which request headers a preflight may approve. `reflect` approves whatever it asks for. -/
inductive AllowedHeaders where
  | reflect
  | only (names : List String)

structure CorsOptions (e : Engine) where
  origins : AllowedOrigins := .any
  methods : List Method := [.get, .head, .post, .put, .patch, .delete]
  allowHeaders : AllowedHeaders := .reflect
  exposeHeaders : List String := []
  maxAge : Option Nat := some 600
  /-- Called with each request whose `Origin` is not allowed, and that origin: a response
  without allow headers says nothing about why it has none. Not called for `Sec-Fetch-Site:
  same-origin`, since a browser sends `Origin` on its own form posts and applies no CORS to them.
  An exception it throws goes to the wrapped handler's `onFailure` rather than costing the
  request its response. -/
  onRefused : Request e.ReqBody → String → e.M Unit := fun _ _ => pure ()

/-- What `Access-Control-Allow-Origin` answers to a request's `Origin`, if anything, and whether
credentials go with it. `*` goes on every response, `Origin` or not, since a stored response
without it would otherwise be reused for a request that needs it. -/
private def allowedOrigin : AllowedOrigins → Option String → Option (String × Bool)
  | .any, _ => some ("*", false)
  | .list origins credentials, some origin =>
    if origins.contains origin then some (origin, credentials) else none
  | .matching allowed credentials, some origin =>
    if allowed origin then some (origin, credentials) else none
  | _, none => none

private def allowOrigin (headers : Headers) : String × Bool → Headers
  | (origin, credentials) =>
    let headers := setHeader headers Header.Name.accessControlAllowOrigin origin
    if credentials then setHeader headers Header.Name.accessControlAllowCredentials "true"
    else headers

/-- A policy that echoes the origin sends `Vary: Origin` on every response, including one to a
request without `Origin`; otherwise a cache would reuse one origin's answer, or one stored from a
non-CORS request, for another. A `Vary` already naming `Origin`, or `*`, covers it. -/
private def varyOnOrigin : AllowedOrigins → Headers → Headers
  | .any, headers => headers
  | _, headers =>
    let covered := ((headers.getAll? Header.Name.vary).getD #[]).any fun value =>
      (value.value.splitOn ",").any fun name =>
        let name := name.trimAscii.toString.toLower
        name == "origin" || name == "*"
    if covered then headers
    else headers.insert Header.Name.vary (Header.Value.ofStringSanitized "Origin")

private def preflightHeaders (options : CorsOptions e) (requested : Option String)
    (headers : Headers) : Headers :=
  let headers := setHeader headers Header.Name.accessControlAllowMethods
    (", ".intercalate (options.methods.map toString))
  let allowHeaders := match options.allowHeaders with
    | .reflect => requested.getD ""
    | .only names => ", ".intercalate names
  let headers := if allowHeaders.isEmpty then headers
    else setHeader headers Header.Name.accessControlAllowHeaders allowHeaders
  match options.maxAge with
  | some seconds => setHeader headers Header.Name.accessControlMaxAge (toString seconds)
  | none => headers

/-- Cross-origin resource sharing (the Fetch standard's CORS protocol).

A preflight, an `OPTIONS` carrying an `Origin` and naming the method it will use in
`Access-Control-Request-Method`, is answered here with `204` and never reaches the handler, so it
succeeds on any path, routed or not. Any other request reaches the handler, and its response
gains the allow headers if its origin is allowed; one from an origin that is not gains none,
which is how a browser learns to withhold it. -/
def cors [ServerEngine e] (options : CorsOptions e := {}) : Middleware e :=
  fun handler =>
    { handler with
      onRequest := fun req => do
        let origin := (req.line.headers.get? Header.Name.origin).map (·.value)
        let allowed := allowedOrigin options.origins origin
        if let some origin := origin then
          let sameOrigin :=
            (req.line.headers.get? Header.Name.secFetchSite).map (·.value) == some "same-origin"
          if allowed.isNone && !sameOrigin then
            try options.onRefused req origin catch err => handler.onFailure err
        let isPreflight := origin.isSome && req.line.method == .options &&
          req.line.headers.contains Header.Name.accessControlRequestMethod
        if isPreflight then
          let requested := (req.line.headers.get? Header.Name.accessControlRequestHeaders).map (·.value)
          let headers := match allowed with
            | some allowed => preflightHeaders options requested (allowOrigin Headers.empty allowed)
            | none => Headers.empty
          ServerEngine.empty { line := { status := .noContent, version := req.line.version,
                                         headers := varyOnOrigin options.origins headers } }
        else
          let resp ← handler.onRequest req
          let headers := match allowed with
            | some allowed =>
              let headers := allowOrigin resp.line.headers allowed
              if options.exposeHeaders.isEmpty then headers
              else setHeader headers Header.Name.accessControlExposeHeaders
                (", ".intercalate options.exposeHeaders)
            | none => resp.line.headers
          let headers := varyOnOrigin options.origins headers
          pure { resp with line := { resp.line with headers } } }

end Middleware
