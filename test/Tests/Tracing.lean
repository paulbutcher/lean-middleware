/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Middleware.CatchAll
import MiddlewareTracing
import Std.Http.Test.Helpers
import Telemetry.Testing

open Std.Http
open Std.Http.Server
open Std.Http.Internal.Test
open Std.Async
open Telemetry
open Telemetry.Sdk (SpanData)
open Middleware (serverSpan parentSpan ServerSpanOptions)

namespace Tests.Tracing

/-- Stands in for whatever a real router records about the pattern it matched. -/
structure MatchedRoute where
  template : String
deriving TypeName

def matchedRoute (extensions : Extensions) : Option String :=
  (extensions.get MatchedRoute).map (·.template)

/-- A router just big enough to have a route template distinct from the paths that match it:
`/users/{id}` for any two-segment path under `/users`, and nothing else. Like a real router it
reports what it matched on the *response*, which is the only channel travelling back outwards. -/
def router : Middleware := fun handler =>
  { handler with
    onRequest := fun req => do
      let response ← handler.onRequest req
      match req.line.uri.path.toDecodedSegments.toList with
      | ["users", _] =>
        return { response with
          extensions := response.extensions.insert ({ template := "/users/{id}" } : MatchedRoute) }
      | _ => return response }

/-- Records the exception a layer below raised and answers with a `500`, the way `catchAll` sits
outside `serverSpan` in the recommended order. -/
def recordingCatchAll (seen : IO.Ref (Option String)) : Middleware := fun handler =>
  { handler with
    onRequest := fun req => do
      try
        handler.onRequest req
      catch e =>
        seen.set (some (toString e))
        Response.internalServerError.text "caught" }

def okHandler : StatelessHandler :=
  { onRequest := fun _ => Response.ok |>.text "ok" }

def statusHandler (status : Status) : StatelessHandler :=
  { onRequest := fun _ => Response.withStatus status |>.text "" }

def throwingHandler (message : String) : StatelessHandler :=
  { onRequest := fun _ => throw (IO.Error.userError message) }

def attr? (span : SpanData) (key : String) : Option Value :=
  (span.attrs.find? (·.fst == key)).map (·.snd)

def expect (condition : Bool) (message : String) : IO Unit :=
  unless condition do throw (IO.userError message)

/-- The single span a capture was expected to produce. -/
def theSpan (captured : Telemetry.Testing.Captured) : IO SpanData := do
  match captured.spans.toList with
  | [span] => return span
  | spans => throw <| IO.userError s!"expected exactly one span, got {spans.length}"

/-- `Telemetry.Testing.capture` installs process-globally, so these run one at a time; `Main`
runs the whole suite sequentially. -/
def captureRequests (raws : List String) (handler : StatelessHandler) :
    IO Telemetry.Testing.Captured := do
  let (_, captured) ← Telemetry.Testing.capture do
    for raw in raws do
      check "request" raw handler.onRequest fun _ => pure ()
  return captured

/--
Two requests to the same endpoint differing only in the path parameter share one span name, and
that name is the route template rather than the bare method: a name carrying the parameter would
make every distinct id its own endpoint.
-/
def routeNamesCollapsePathParametersTest : IO Unit := do
  let stack := serverSpan matchedRoute {} (router okHandler)
  let captured ← captureRequests [mkGetClose "/users/1", mkGetClose "/users/2"] stack
  match captured.spans.toList with
  | [first, second] =>
    expect (attr? first Conventions.urlPath != attr? second Conventions.urlPath)
      "expected the two requests to differ in url.path"
    expect (first.name == second.name)
      s!"expected one span name, got {first.name.quote} and {second.name.quote}"
    expect (first.name != "GET")
      "expected the span to be renamed for the route, not left as the method"
    expect (attr? first Conventions.httpRoute == some (.str "/users/{id}"))
      s!"expected http.route on the span, got {repr (attr? first Conventions.httpRoute)}"
  | spans => throw <| IO.userError s!"expected two spans, got {spans.length}"

/-- A request matching no route carries no `http.route` at all, rather than a guess derived from
its path. -/
def unmatchedRouteHasNoRouteAttributeTest : IO Unit := do
  let stack := serverSpan matchedRoute {} (router okHandler)
  let span ← theSpan (← captureRequests [mkGetClose "/nothing/here"] stack)
  expect (attr? span Conventions.httpRoute == none)
    s!"expected no http.route, got {repr (attr? span Conventions.httpRoute)}"
  expect (span.name == "GET") s!"expected the method-only name, got {span.name.quote}"

/-- A failure below the span leaves it with status `error` and the exception's own message, and
the exception still reaches the layer outside, which is what makes `catchAll` able to answer. -/
def exceptionIsRecordedAndRethrownTest : IO Unit := do
  let seen ← IO.mkRef none
  let stack := recordingCatchAll seen (serverSpan matchedRoute {} (throwingHandler "boom"))
  let span ← theSpan (← captureRequests [mkGetClose "/users/1"] stack)
  expect (span.status == .error) s!"expected status error, got {repr span.status}"
  expect ((span.statusMessage.getD "").contains "boom")
    s!"expected the exception's message on the span, got {repr span.statusMessage}"
  expect ((← seen.get).isSome) "expected the exception to reach the layer outside the span"
  -- No response came back to the span, so there is nothing to record a status code from.
  expect (attr? span Conventions.httpResponseStatusCode == none)
    "expected no http.response.status_code on a span that ended in an exception"

/-- Code below the middleware runs with the request's `SpanContext` in its extensions, and it is
this span's context: without that nothing below can open a child of the server span. -/
def spanContextReachesTheHandlerTest : IO Unit := do
  let observed ← IO.mkRef none
  let handler : StatelessHandler :=
    { onRequest := fun req => do
        observed.set (parentSpan req)
        Response.ok |>.text "ok" }
  let span ← theSpan (← captureRequests [mkGetClose "/users/1"]
    (serverSpan matchedRoute {} (router handler)))
  match ← observed.get with
  | none => throw <| IO.userError "expected a SpanContext in the handler's request extensions"
  | some ctx =>
    expect (ctx == span.ctx)
      "expected the handler's SpanContext to be the server span's own"

/-- A `4xx` is the client sending something wrong; only a `5xx` is this server failing to serve,
so only a `5xx` sets the span's status. -/
def onlyServerErrorsSetErrorStatusTest : IO Unit := do
  for (status, expected) in
      [(Status.notFound, StatusCode.unset), (Status.internalServerError, StatusCode.error)] do
    let stack := serverSpan matchedRoute {} (statusHandler status)
    let span ← theSpan (← captureRequests [mkGetClose "/users/1"] stack)
    expect (span.status == expected)
      s!"expected {repr expected} for {status.toCode}, got {repr span.status}"
    expect (attr? span Conventions.httpResponseStatusCode == some (.int status.toCode.toNat))
      s!"expected http.response.status_code {status.toCode}, got \
        {repr (attr? span Conventions.httpResponseStatusCode)}"

/-- A query string can carry credentials, so `url.query` is recorded only when asked for. -/
def queryRecordedOnlyOnRequestTest : IO Unit := do
  let raw := mkGetClose "/users/1?token=hunter2"
  let byDefault ← theSpan (← captureRequests [raw] (serverSpan matchedRoute {} (router okHandler)))
  expect (attr? byDefault Conventions.urlQuery == none)
    s!"expected no url.query by default, got {repr (attr? byDefault Conventions.urlQuery)}"
  let optedIn ← theSpan (← captureRequests [raw]
    (serverSpan matchedRoute { recordQuery := true } (router okHandler)))
  expect (attr? optedIn Conventions.urlQuery == some (.str "token=hunter2"))
    s!"expected url.query when opted in, got {repr (attr? optedIn Conventions.urlQuery)}"

/-- A skipped request opens no span at all, which is the only way to keep an exporter from
seeing one export per static asset while `Telemetry` implements no sampling. -/
def skippedRequestsProduceNoSpanTest : IO Unit := do
  let options : ServerSpanOptions :=
    { skip := fun req => req.line.uri.path.toDecodedSegments.toList.head? == some "assets" }
  let stack := serverSpan matchedRoute options (router okHandler)
  let captured ← captureRequests [mkGetClose "/assets/app.css", mkGetClose "/users/1"] stack
  expect (captured.spans.size == 1)
    s!"expected the skipped request to produce no span, got {captured.spans.size} spans"

def run : IO Unit :=
  runGroup "Middleware.Tracing" do
    routeNamesCollapsePathParametersTest
    unmatchedRouteHasNoRouteAttributeTest
    exceptionIsRecordedAndRethrownTest
    spanContextReachesTheHandlerTest
    onlyServerErrorsSetErrorStatusTest
    queryRecordedOnlyOnRequestTest
    skippedRequestsProduceNoSpanTest

end Tests.Tracing
