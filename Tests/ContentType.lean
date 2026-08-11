/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Middleware.ContentType
import Std.Http.Test.Helpers

open Std.Http
open Std.Http.Server
open Std.Http.Internal.Test
open Middleware (contentType)

namespace Tests.ContentType

def bareHandler : StatelessHandler :=
  { onRequest := fun _ => pure ({ body := Body.Any.ofBody ({} : Body.Empty) } : Response Body.Any) }

def jsonHandler : StatelessHandler :=
  { onRequest := fun _ => Response.ok |>.json "{}" }

def inferredFromExtensionTest : IO Unit :=
  check "infers text/css from .css path" (mkGetClose "/style.css")
    (contentType "application/octet-stream" bareHandler).onRequest fun response =>
      assertContains response "Content-Type: text/css; charset=utf-8"

def fallsBackToDefaultTest : IO Unit :=
  check "falls back to octet-stream for unknown extension" (mkGetClose "/data.unknownext")
    (contentType "application/octet-stream" bareHandler).onRequest fun response =>
      assertContains response "Content-Type: application/octet-stream"

def noExtensionTest : IO Unit :=
  check "falls back to octet-stream with no extension" (mkGetClose "/no-extension")
    (contentType "application/octet-stream" bareHandler).onRequest fun response =>
      assertContains response "Content-Type: application/octet-stream"

def doesNotOverrideExistingTest : IO Unit :=
  check "does not override a Content-Type the handler already set" (mkGetClose "/data.txt")
    (contentType "application/octet-stream" jsonHandler).onRequest fun response => do
      assertContains response "Content-Type: application/json"
      assertAbsent response "text/plain"

def run : IO Unit :=
  runGroup "Middleware.ContentType" do
    inferredFromExtensionTest
    fallsBackToDefaultTest
    noExtensionTest
    doesNotOverrideExistingTest

end Tests.ContentType
