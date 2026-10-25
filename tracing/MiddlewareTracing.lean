/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import Middleware.Core
public import Middleware.Proxy
public import Std.Http.Server.Connection
public import Telemetry

public section

open Std.Http
open Std.Http.Server (RemoteAddr)
open Routing
open Telemetry

namespace Middleware

/-- The span a request is running under, for handing to an operation below so that its spans
become children of it. `none` when no SDK is installed, which is what makes an uninstrumented
build cost nothing. -/
def parentSpan {α : Type} (req : Request α) : Option SpanContext :=
  req.extensions.get SpanContext

/-! Attribute names the OpenTelemetry semantic conventions define for HTTP servers but
`Telemetry.Conventions` doesn't carry, since that library speaks no HTTP. -/

namespace Conventions

def clientAddress : String := "client.address"
def clientPort : String := "client.port"
def userAgentOriginal : String := "user_agent.original"

end Conventions

structure ServerSpanOptions (e : Engine) where
  /-- Requests this returns `true` for are passed straight through, with no span opened at all.
  `Telemetry` implements no sampling, so without this every static asset served by `file`
  becomes its own export. -/
  skip : Request e.ReqBody → Bool := fun _ => false
  /-- Record `url.query`. Off by default: a query string can carry credentials, and a span is
  usually kept for longer and read by more people than a request ever is. -/
  recordQuery : Bool := false
  /-- Record `client.address`, and `client.port` when the source carries one, from the
  `ForwardedFor` extension if `forwardedRemoteAddr` attached one, else from the `RemoteAddr`
  extension `Std.Http.Server` attaches. A request that arrived through a proxy gets an address and
  no port, since `X-Forwarded-For` carries none. LeanIn attaches no `RemoteAddr`, so on that engine
  only a forwarded address is recorded. -/
  recordClientAddress : Bool := true
  /-- Record `user_agent.original`. -/
  recordUserAgent : Bool := true

/-- The conventions keep the address and the port apart, and `ToString RemoteAddr` joins them
(`addr:port`, or `[addr]:port` for v6). An address with the port appended takes one value per
connection rather than one per client, and matches nothing else keyed on a bare address. -/
private def clientAddressAndPort {α : Type} (req : Request α) : Option (String × Option UInt16) :=
  (req.extensions.get ForwardedFor).map (fun forwarded => (forwarded.addr, none))
    <|> (req.extensions.get RemoteAddr).map fun remote =>
      (toString remote.addr.ipAddr, some remote.addr.port)

/-- The convention's `url.query` is the query without its leading `?`, which is where
`ToString URI.Query` differs from it. -/
private def queryString {α : Type} (req : Request α) : String :=
  String.intercalate "&" <|
    req.line.uri.query.toList.map fun (key, value) => URI.Query.formatQueryParam key value

private def requestAttrs {e : Engine} (req : Request e.ReqBody) (method : String)
    (options : ServerSpanOptions e) : Attrs := Id.run do
  let mut attrs : Attrs :=
    [(Telemetry.Conventions.httpRequestMethod, method),
     (Telemetry.Conventions.urlPath, toString req.line.uri.path)]
  if options.recordQuery then
    let query := queryString req
    unless query.isEmpty do
      attrs := attrs ++ [(Telemetry.Conventions.urlQuery, Value.str query)]
  if options.recordClientAddress then
    if let some (addr, port?) := clientAddressAndPort req then
      attrs := attrs ++ [(Conventions.clientAddress, Value.str addr)]
      if let some port := port? then
        attrs := attrs ++ [(Conventions.clientPort, Value.int port.toNat)]
  if options.recordUserAgent then
    if let some agent := req.line.headers.get? Header.Name.userAgent then
      attrs := attrs ++ [(Conventions.userAgentOriginal, Value.str agent.value)]
  return attrs

/--
Opens an OpenTelemetry `server` span around every request and publishes its `SpanContext` into
the request's extensions, so that anything below can open children of it (see `parentSpan`).

`routeName` is asked for the low-cardinality route template the request matched, and is given
the *response*'s extensions, not the request's: a router below has already been handed its
request by the time it decides what matched, so the response is the only channel that travels
back the other way. An application routing with `routing` passes `Routing.matchedPattern?`;
one using another router passes a function derived from whatever that router records.

The span starts out named for the method alone and is renamed to `"{method} {route}"` once
`routeName` answers, because the name is what spans are grouped by and a name carrying a path
parameter makes every distinct parameter value its own endpoint. A request matching no route
keeps the method-only name and gets no `http.route` attribute rather than a guessed one.

Only a `5xx` sets the span's status to `error`; a `4xx` is the client sending something wrong,
not the server failing to serve it. An exception needs no handling here: `Telemetry.span`
already reports the span with status `error` and the exception's message, and re-raises.
-/
def serverSpan {e : Engine} [ServerEngine e] (routeName : Extensions → Option String)
    (options : ServerSpanOptions e := {}) : Middleware e := fun handler =>
  { handler with
    onRequest := fun req =>
      if options.skip req then
        handler.onRequest req
      else
        -- The engine fixes the handler monad, which has no slot for a span, so the reader layer
        -- is established here. Every server span is therefore a root, which is right until
        -- `traceparent` propagation exists upstream.
        runTelemetry do
          let method := toString req.line.method
          span method (kind := .server) (attrs := requestAttrs req method options)
            fun current => do
              let req := match current.context with
                | some ctx => { req with extensions := req.extensions.insert ctx }
                | none => req
              let response ← handler.onRequest req
              let code := response.line.status.toCode
              current.add [(Telemetry.Conventions.httpResponseStatusCode, code.toNat)]
              if let some route := routeName response.extensions then
                current.add [(Telemetry.Conventions.httpRoute, route)]
                current.rename s!"{method} {route}"
              if code ≥ 500 then
                current.setStatus .error none
              return response }

end Middleware
