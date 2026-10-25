/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import Middleware.CacheControl
public import RoutingStd
public import Middleware.NotModified
public import Std.Http.Test.Helpers

public section

open Std.Http
open Routing
open Std.Http.Internal.Test
open Middleware (cacheControl notModified CachePolicy ETag)

namespace Tests.CacheControl

def bareHandler : StatelessHandler .std :=
  { onRequest := fun _ => Response.ok |>.text "ok" }

def etaggedHandler : StatelessHandler .std :=
  { onRequest := fun _ => do
      let resp ← Response.ok |>.text "hello"
      let (name, value) := ETag.serialize { value := "abc123", weak := false }
      pure ({ resp with
        line := { resp.line with headers := resp.line.headers.insert name value } } :
          Response Body.Any) }

def defaultPolicyTest : IO Unit :=
  check "defaults to no-cache" (mkGetClose "/") (cacheControl .noCache bareHandler).onRequest
    fun response => assertContains response "Cache-Control: no-cache"

def immutableMaxAgeTest : IO Unit :=
  check "a shared immutable max-age renders all three directives" (mkGetClose "/")
    (cacheControl (.maxAge 31536000 (immutable := true)) bareHandler).onRequest fun response =>
      assertContains response "Cache-Control: public, max-age=31536000, immutable"

def privateMaxAgeTest : IO Unit :=
  check "an unshared mutable max-age renders neither public nor immutable" (mkGetClose "/")
    (cacheControl (.maxAge 600 (shared := false)) bareHandler).onRequest fun response => do
      assertContains response "Cache-Control: private, max-age=600"
      assertAbsent response "immutable"

def handlerPolicyWinsTest : IO Unit :=
  check "leaves a policy the handler chose for itself" (mkGetClose "/")
    (cacheControl (e := .std) .noCache
      { onRequest := fun _ => Response.ok.header! "Cache-Control" "no-store" |>.text "ok" }).onRequest
    fun response => do
      assertContains response "Cache-Control: no-store"
      assertAbsent response "no-cache"

/-- The whole point of the layer: a client that already revalidates has to keep being told the
policy, and the only response it gets is the `304`. -/
def survivesNotModifiedTest : IO Unit :=
  check "a 304 still carries the policy set beneath notModified"
    (mkGet "/" "If-None-Match: \"abc123\"\x0d\nConnection: close\x0d\n")
    (notModified (cacheControl (.maxAge 600) etaggedHandler)).onRequest fun response => do
      assertStatus response "HTTP/1.1 304"
      assertContains response "Cache-Control: public, max-age=600"

def run : IO Unit :=
  runGroup "Middleware.CacheControl" do
    defaultPolicyTest
    immutableMaxAgeTest
    privateMaxAgeTest
    handlerPolicyWinsTest
    survivesNotModifiedTest

end Tests.CacheControl
