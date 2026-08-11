/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Middleware.Proxy
import Std.Http.Test.Helpers

open Std.Http
open Std.Http.Server
open Std.Http.Internal.Test
open Middleware (forwardedScheme forwardedRemoteAddr requestOrigin Scheme ForwardedFor)

namespace Tests.Proxy

def echoSchemeHandler : StatelessHandler :=
  { onRequest := fun req => do
      let scheme := match (req.extensions.get Scheme).getD .http with
        | .http => "http"
        | .https => "https"
      Response.ok |>.text scheme }

def echoForwardedForHandler : StatelessHandler :=
  { onRequest := fun req => do
      let addr := (req.extensions.get ForwardedFor).map (·.addr) |>.getD "<missing>"
      Response.ok |>.text addr }

def echoOriginHandler : StatelessHandler :=
  { onRequest := fun req => Response.ok |>.text ((requestOrigin req).getD "<no-origin>") }

def httpsHeaderRecognizedTest : IO Unit :=
  check "X-Forwarded-Proto: https is recognized"
    (mkGet "/" "X-Forwarded-Proto: https\x0d\nConnection: close\x0d\n")
    (forwardedScheme Middleware.Header.Name.xForwardedProto echoSchemeHandler).onRequest fun response =>
      assertContains response "https"

def httpHeaderCaseInsensitiveTest : IO Unit :=
  check "the value is matched case-insensitively"
    (mkGet "/" "X-Forwarded-Proto: HTTPS\x0d\nConnection: close\x0d\n")
    (forwardedScheme Middleware.Header.Name.xForwardedProto echoSchemeHandler).onRequest fun response =>
      assertContains response "https"

def garbageSchemeIgnoredTest : IO Unit :=
  check "a garbage value is ignored, defaulting downstream to http"
    (mkGet "/" "X-Forwarded-Proto: carrier-pigeon\x0d\nConnection: close\x0d\n")
    (forwardedScheme Middleware.Header.Name.xForwardedProto echoSchemeHandler).onRequest fun response =>
      assertContains response "http"

def noHeaderDefaultsToHttpTest : IO Unit :=
  check "no header at all defaults to http" (mkGetClose "/") (forwardedScheme Middleware.Header.Name.xForwardedProto echoSchemeHandler).onRequest
    fun response => assertContains response "http"

def forwardedForTakesLastEntryTest : IO Unit :=
  check "the last comma-separated entry is used, not the first"
    (mkGet "/" "X-Forwarded-For: 203.0.113.9, 10.0.0.1, 10.0.0.2\x0d\nConnection: close\x0d\n")
    (forwardedRemoteAddr Middleware.Header.Name.xForwardedFor echoForwardedForHandler).onRequest fun response =>
      assertContains response "10.0.0.2"

def forwardedForAbsentTest : IO Unit :=
  check "no X-Forwarded-For header leaves ForwardedFor unset" (mkGetClose "/")
    (forwardedRemoteAddr Middleware.Header.Name.xForwardedFor echoForwardedForHandler).onRequest fun response =>
      assertContains response "<missing>"

def requestOriginReflectsSchemeTest : IO Unit :=
  check "requestOrigin reflects the forwarded scheme and Host header"
    (mkGet "/" "X-Forwarded-Proto: https\x0d\nConnection: close\x0d\n")
    (forwardedScheme Middleware.Header.Name.xForwardedProto echoOriginHandler).onRequest fun response =>
      assertContains response "https://example.com"

def requestOriginDefaultsToHttpTest : IO Unit :=
  check "requestOrigin defaults to http without a forwarded scheme"
    (mkGetClose "/") echoOriginHandler.onRequest
    fun response => assertContains response "http://example.com"

def run : IO Unit :=
  runGroup "Middleware.Proxy" do
    httpsHeaderRecognizedTest
    httpHeaderCaseInsensitiveTest
    garbageSchemeIgnoredTest
    noHeaderDefaultsToHttpTest
    forwardedForTakesLastEntryTest
    forwardedForAbsentTest
    requestOriginReflectsSchemeTest
    requestOriginDefaultsToHttpTest

end Tests.Proxy
