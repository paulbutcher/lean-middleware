/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import Middleware.Cors
public import Std.Http.Test.Helpers

public section

open Std.Http
open Std.Http.Server
open Std.Http.Internal.Test
open Middleware (cors CorsOptions AllowedOrigins)

namespace Tests.Cors

def reached : StatelessHandler :=
  { onRequest := fun _ => Response.ok |>.text "reached the handler" }

def get (origin : String) : String :=
  mkGet "/" s!"Origin: {origin}\x0d\nConnection: close\x0d\n"

def preflight (origin : String) (headers : String := "") : String :=
  s!"OPTIONS / HTTP/1.1\x0d\nHost: example.com\x0d\nOrigin: {origin}\x0d\n" ++
    s!"Access-Control-Request-Method: PUT\x0d\n{headers}Connection: close\x0d\n\x0d\n"

def listed : CorsOptions := { origins := .list ["https://app.example"] }

def noOriginTest : IO Unit :=
  check "a request without Origin gets no CORS headers" (mkGetClose "/") (cors {} reached).onRequest
    fun response => do
      assertContains response "reached the handler"
      assertAbsent response "Access-Control"

def anyOriginTest : IO Unit :=
  check "any origin is answered with *" (get "https://elsewhere.example") (cors {} reached).onRequest
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
    (cors { listed with credentials := true } reached).onRequest fun response =>
      assertContains response "Access-Control-Allow-Credentials: true"

def credentialsWithAnyTest : IO Unit :=
  check "credentials are never paired with *" (get "https://app.example")
    (cors { credentials := true } reached).onRequest fun response => do
      assertContains response "Access-Control-Allow-Origin: *"
      assertAbsent response "Access-Control-Allow-Credentials"

def preflightTest : IO Unit :=
  check "a preflight is answered without reaching the handler"
    (preflight "https://app.example" "Access-Control-Request-Headers: content-type, authorization\x0d\n")
    (cors { listed with maxAge := some 86400 } reached).onRequest fun response => do
      assertStatus response "HTTP/1.1 204"
      assertAbsent response "reached the handler"
      assertContains response "Access-Control-Allow-Origin: https://app.example"
      assertContains response "Access-Control-Allow-Methods: GET, HEAD, POST, PUT, PATCH, DELETE"
      assertContains response "Access-Control-Allow-Headers: content-type, authorization"
      assertContains response "Access-Control-Max-Age: 86400"

def preflightFixedHeadersTest : IO Unit :=
  check "a fixed header list is sent rather than the requested one"
    (preflight "https://app.example" "Access-Control-Request-Headers: x-anything\x0d\n")
    (cors { listed with allowHeaders := some ["content-type"] } reached).onRequest fun response =>
      assertContains response "Access-Control-Allow-Headers: content-type"

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

def headerInjectionTest : IO Unit :=
  check "an origin cannot inject a header" (get "https://a.example\x0d\nX-Injected: 1")
    (cors { origins := .matching fun _ => true } reached).onRequest fun response =>
      assertAbsent response "X-Injected: 1\x0d\n"

def run : IO Unit :=
  runGroup "Middleware.Cors" do
    noOriginTest
    anyOriginTest
    listedOriginTest
    unlistedOriginTest
    credentialsTest
    credentialsWithAnyTest
    preflightTest
    preflightFixedHeadersTest
    unlistedPreflightTest
    plainOptionsTest
    exposeHeadersTest
    headerInjectionTest

end Tests.Cors
