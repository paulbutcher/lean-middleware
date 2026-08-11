/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Middleware.Core
import Std.Http.Test.Helpers

open Std.Http
open Std.Http.Server
open Std.Http.Internal.Test

namespace Tests.Core

/-- Adds an `x-order` header on the way back out, recording when this layer ran. -/
def markerMiddleware (name : String) : Middleware :=
  fun handler =>
    { handler with
      onRequest := fun req => do
        let resp ← handler.onRequest req
        pure { resp with
          line := { resp.line with headers := resp.line.headers.insert! "x-order" name } } }

def baseHandler : TestHandler := fun _ => Response.ok |>.text "base"

/--
`Middleware.apply` runs pre-processing outermost-first, so post-processing (like the header
insertion here) happens innermost-first: with `[markerMiddleware "A", markerMiddleware "B"]`,
"B" wraps the base handler and finishes its post-processing before "A" does, so "B"'s header
is inserted first.
-/
def orderTest : IO Unit := do
  let stack := Middleware.apply [markerMiddleware "A", markerMiddleware "B"]
    { onRequest := baseHandler }
  check "middleware order" (mkGetClose) stack.onRequest fun response => do
    let text := String.fromUTF8! response
    assertContains response "X-Order: B"
    assertContains response "X-Order: A"
    let beforeA := (text.splitOn "X-Order: A").head!
    unless (beforeA.splitOn "X-Order: B").length > 1 do
      throw <| IO.userError s!"expected 'X-Order: B' before 'X-Order: A', got:\n{text.quote}"

def idTest : IO Unit :=
  check "id is a no-op" (mkGetClose) (Middleware.id { onRequest := baseHandler }).onRequest fun response => do
    assertStatus response "HTTP/1.1 200"
    assertContains response "base"

def run : IO Unit :=
  runGroup "Middleware.Core" do
    orderTest
    idTest

end Tests.Core
