/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import Middleware.ContentType
public import Std.Http.Test.Helpers

public section

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

def presetContentTypeHandler (value : String) : StatelessHandler :=
  { onRequest := fun _ =>
      Response.ok.header Header.Name.contentType (Header.Value.ofString! value) |>.text "body" }

/-- Whatever already-set `Content-Type` a handler produces, `contentType` leaves it alone --
checked against a handful of varied values (not just the single `application/json`
`doesNotOverrideExistingTest` already covers), on a request path whose extension would otherwise
infer something different. -/
def alreadySetContentTypeNeverClobberedTest : IO Unit := do
  let values :=
    [ "application/json", "text/x-custom; charset=utf-8", "application/vnd.api+json",
      "x-foo/x-bar", "text/plain", "application/octet-stream" ]
  for value in values do
    check s!"an already-set Content-Type of {value.quote} is preserved" (mkGetClose "/style.css")
      (contentType "application/octet-stream" (presetContentTypeHandler value)).onRequest
      fun response => assertContains response s!"Content-Type: {value}"

def run : IO Unit :=
  runGroup "Middleware.ContentType" do
    inferredFromExtensionTest
    fallsBackToDefaultTest
    noExtensionTest
    doesNotOverrideExistingTest
    alreadySetContentTypeNeverClobberedTest

end Tests.ContentType
