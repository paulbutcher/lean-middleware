/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import Middleware.Cors
public import Middleware.CatchAll
public import RoutingStd
public import Std.Http.Test.Helpers

public section

open Std.Http
open Routing
open Std.Http.Internal.Test
open Middleware (cors catchAll CorsOptions AllowedOrigins)

namespace Tests.Cors

def reached : StatelessHandler .std :=
  { onRequest := fun _ => Response.ok |>.text "reached the handler" }

def varying (value : String) : StatelessHandler .std :=
  { onRequest := fun _ => Response.ok.header! "Vary" value |>.text "ok" }

def get (origin : String) (headers : String := "") : String :=
  mkGet "/" s!"Origin: {origin}\x0d\n{headers}Connection: close\x0d\n"

def preflight (origin : String) (headers : String := "") : String :=
  s!"OPTIONS / HTTP/1.1\x0d\nHost: example.com\x0d\nOrigin: {origin}\x0d\n" ++
    s!"Access-Control-Request-Method: PUT\x0d\n{headers}Connection: close\x0d\n\x0d\n"

def listed : CorsOptions .std := { origins := .list ["https://app.example"] }

def noOriginTest : IO Unit :=
  check "a request without Origin gets no allow headers, but still varies on Origin"
    (mkGetClose "/") (cors listed reached).onRequest fun response => do
      assertContains response "reached the handler"
      assertAbsent response "Access-Control"
      assertContains response "Vary: Origin"

def anyOriginTest : IO Unit :=
  for (name, raw) in [("with", get "https://elsewhere.example"), ("without", mkGetClose "/")] do
    check s!"a request {name} Origin is answered with * under any" raw (cors {} reached).onRequest
      fun response => do
        assertContains response "Access-Control-Allow-Origin: *"
        assertAbsent response "Vary"

def listedOriginTest : IO Unit :=
  check "a listed origin is echoed, with Vary" (get "https://app.example") (cors listed reached).onRequest
    fun response => do
      assertContains response "Access-Control-Allow-Origin: https://app.example"
      assertContains response "Vary: Origin"

def unlistedOriginTest : IO Unit :=
  check "an unlisted origin reaches the handler but gets no allow headers"
    (get "https://evil.example") (cors listed reached).onRequest fun response => do
      assertContains response "reached the handler"
      assertAbsent response "Access-Control-Allow-Origin"
      assertContains response "Vary: Origin"

def credentialsTest : IO Unit :=
  check "credentials are allowed for a listed origin" (get "https://app.example")
    (cors { origins := .list ["https://app.example"] (credentials := true) } reached).onRequest
    fun response => assertContains response "Access-Control-Allow-Credentials: true"

def refusedTest : IO Unit := do
  let refused ← IO.mkRef ([] : List String)
  let options := { listed with onRefused := fun _ origin => refused.modify (· ++ [origin]) }
  for raw in [get "https://evil.example", preflight "https://other.example",
      get "https://app.example", mkGetClose "/"] do
    check "a request is answered whether or not its origin is refused" raw
      (cors options reached).onRequest fun response => assertStatus response "HTTP/1.1 2"
  let seen ← refused.get
  unless seen == ["https://evil.example", "https://other.example"] do
    throw <| IO.userError s!"expected the two refused origins to be reported, got {seen}"

def sameOriginTest : IO Unit := do
  let refused ← IO.mkRef ([] : List String)
  let options := { listed with onRefused := fun _ origin => refused.modify (· ++ [origin]) }
  for (origin, site) in [("https://own.example", "same-origin"), ("https://sibling.example", "same-site")] do
    check s!"an unlisted origin under Sec-Fetch-Site: {site} is answered"
      (get origin s!"Sec-Fetch-Site: {site}\x0d\n") (cors options reached).onRequest fun response =>
        assertStatus response "HTTP/1.1 200"
  let seen ← refused.get
  unless seen == ["https://sibling.example"] do
    throw <| IO.userError s!"expected only the same-site origin to be reported, got {seen}"

def throwingRefusedTest : IO Unit := do
  let failed ← IO.mkRef false
  let handler := { reached with onFailure := fun _ => failed.set true }
  let options := { listed with onRefused := fun _ _ => throw (IO.userError "boom") }
  check "an onRefused that throws still lets the request be answered" (get "https://evil.example")
    (cors options handler).onRequest fun response => assertStatus response "HTTP/1.1 200"
  unless (← failed.get) do
    throw <| IO.userError "expected onRefused's exception to reach onFailure"

def preflightTest : IO Unit :=
  check "a preflight is answered without reaching the handler"
    (preflight "https://app.example" "Access-Control-Request-Headers: content-type, authorization\x0d\n")
    (cors { listed with methods := [.get, .put], maxAge := some 86400 } reached).onRequest
    fun response => do
      assertStatus response "HTTP/1.1 204"
      assertAbsent response "reached the handler"
      assertContains response "Access-Control-Allow-Origin: https://app.example"
      assertContains response "Access-Control-Allow-Methods: GET, PUT"
      assertContains response "Access-Control-Allow-Headers: content-type, authorization"
      assertContains response "Access-Control-Max-Age: 86400"

def preflightFixedHeadersTest : IO Unit :=
  check "a fixed header list is sent rather than the requested one"
    (preflight "https://app.example" "Access-Control-Request-Headers: x-anything\x0d\n")
    (cors { listed with allowHeaders := .only ["content-type"] } reached).onRequest fun response =>
      assertContains response "Access-Control-Allow-Headers: content-type"

def preflightExposeHeadersTest : IO Unit :=
  check "a preflight does not list exposed headers" (preflight "https://app.example")
    (cors { listed with exposeHeaders := ["x-total-count"] } reached).onRequest fun response =>
      assertAbsent response "Access-Control-Expose-Headers"

def unlistedPreflightTest : IO Unit :=
  check "a preflight from an unlisted origin is answered with nothing to allow"
    (preflight "https://evil.example") (cors listed reached).onRequest fun response => do
      assertStatus response "HTTP/1.1 204"
      assertAbsent response "Access-Control-Allow"

def plainOptionsTest : IO Unit :=
  check "an OPTIONS without Access-Control-Request-Method is not a preflight"
    (s!"OPTIONS / HTTP/1.1\x0d\nHost: example.com\x0d\nOrigin: https://app.example\x0d\n" ++
      "Connection: close\x0d\n\x0d\n")
    (cors listed reached).onRequest fun response =>
      assertContains response "reached the handler"

def exposeHeadersTest : IO Unit :=
  check "exposed headers are listed on actual responses" (get "https://app.example")
    (cors { listed with exposeHeaders := ["x-total-count"] } reached).onRequest fun response =>
      assertContains response "Access-Control-Expose-Headers: x-total-count"

def failureTest : IO Unit :=
  let failing : StatelessHandler .std := { onRequest := fun _ => throw (IO.Error.userError "boom") }
  check "a handler failure still carries the allow headers" (get "https://app.example")
    (Middleware.apply [cors listed, catchAll] failing).onRequest fun response => do
      assertStatus response "HTTP/1.1 500"
      assertContains response "Access-Control-Allow-Origin: https://app.example"

def existingVaryTest : IO Unit :=
  check "a handler's own Vary survives alongside Origin" (get "https://app.example")
    (cors listed (varying "Accept-Encoding")).onRequest fun response => do
      assertContains response "Vary: Accept-Encoding"
      assertContains response "Vary: Origin"

def varyNotDuplicatedTest : IO Unit :=
  check "a Vary already naming Origin is not repeated" (get "https://app.example")
    (cors listed (varying "accept-encoding, origin")).onRequest fun response => do
      let found := ((String.fromUTF8! response).splitOn "Vary:").length - 1
      unless found == 1 do
        throw <| IO.userError s!"expected exactly one Vary header, found {found}"

def run : IO Unit :=
  runGroup "Middleware.Cors" do
    noOriginTest
    anyOriginTest
    listedOriginTest
    unlistedOriginTest
    credentialsTest
    refusedTest
    sameOriginTest
    throwingRefusedTest
    preflightTest
    preflightFixedHeadersTest
    preflightExposeHeadersTest
    unlistedPreflightTest
    plainOptionsTest
    exposeHeadersTest
    failureTest
    existingVaryTest
    varyNotDuplicatedTest

end Tests.Cors
