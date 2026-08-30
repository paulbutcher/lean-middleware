/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import Middleware.Charset
public import Std.Http.Test.Helpers

public section

open Std.Http
open Std.Http.Server
open Std.Http.Internal.Test
open Middleware (defaultCharset)

namespace Tests.Charset

/-- Builds a response with exactly the given `Content-Type` and no body, deliberately not via
`.text`, which always sets its own `Content-Type` (additively, per `Headers.insert`'s multi-value
semantics) regardless of what the builder already has, which would leave two `Content-Type`
headers on the response and defeat what this test is checking. -/
def withContentType (value : String) : StatelessHandler :=
  { onRequest := fun _ =>
      pure ({
        line := { headers := Headers.empty.insert Header.Name.contentType (Header.Value.ofString! value) },
        body := Body.Any.ofBody ({} : Body.Empty) } : Response Body.Any) }

def noContentTypeHandler : StatelessHandler :=
  { onRequest := fun _ => pure ({ body := Body.Any.ofBody ({} : Body.Empty) } : Response Body.Any) }

def appendsToPlainTextTest : IO Unit :=
  check "text/plain gets a charset appended" (mkGetClose "/")
    (defaultCharset "utf-8" (withContentType "text/plain")).onRequest fun response =>
      assertContains response "Content-Type: text/plain; charset=utf-8"

def appendsToXmlTest : IO Unit :=
  check "application/xml gets a charset appended" (mkGetClose "/")
    (defaultCharset "utf-8" (withContentType "application/xml")).onRequest fun response =>
      assertContains response "Content-Type: application/xml; charset=utf-8"

def leavesExistingCharsetTest : IO Unit :=
  check "a Content-Type with a charset already is untouched" (mkGetClose "/")
    (defaultCharset "utf-8" (withContentType "text/plain; charset=iso-8859-1")).onRequest
    fun response => do
      assertContains response "charset=iso-8859-1"
      assertAbsent response "charset=utf-8"

def leavesNonTextTypeTest : IO Unit :=
  check "a non-text Content-Type is untouched" (mkGetClose "/")
    (defaultCharset "utf-8" (withContentType "image/png")).onRequest fun response => do
      assertContains response "Content-Type: image/png"
      assertAbsent response "charset"

def leavesNoContentTypeTest : IO Unit :=
  check "no Content-Type at all is a no-op" (mkGetClose "/")
    (defaultCharset "utf-8" noContentTypeHandler).onRequest fun response =>
      assertAbsent response "charset"

/-- Stacking `defaultCharset` twice is the accident an application makes by listing it in more
than one place; the second pass has to see the first pass's own output as already-charsetted. -/
def doubleApplicationAppendsOnceTest : IO Unit :=
  check "running defaultCharset twice still yields exactly one charset parameter" (mkGetClose "/")
    (defaultCharset "utf-8" (defaultCharset "utf-8" (withContentType "text/plain"))).onRequest
    fun response => do
      let text := String.fromUTF8! response
      let occurrences := (text.splitOn "charset=").length - 1
      unless occurrences == 1 do
        throw <| IO.userError s!"expected exactly one charset parameter, found {occurrences} in:\n{text}"

def run : IO Unit :=
  runGroup "Middleware.Charset" do
    appendsToPlainTextTest
    appendsToXmlTest
    leavesExistingCharsetTest
    leavesNonTextTypeTest
    leavesNoContentTypeTest
    doubleApplicationAppendsOnceTest

end Tests.Charset
