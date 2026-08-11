/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Middleware.CatchAll
import Std.Http.Test.Helpers

open Std.Http
open Std.Http.Server
open Std.Http.Internal.Test
open Std.Async
open Middleware (catchAll)

namespace Tests.CatchAll

def throwingHandler : StatelessHandler :=
  { onRequest := fun _ => throw (IO.Error.userError "boom") }

def passthroughHandler : StatelessHandler :=
  { onRequest := fun _ => Response.ok |>.text "ok" }

def caughtErrorTest : IO Unit :=
  check "uncaught error becomes 500" (mkGetClose) (catchAll (fun _ => pure ()) throwingHandler).onRequest
    fun response => assertStatus response "HTTP/1.1 500"

def passthroughTest : IO Unit :=
  check "normal response is untouched" (mkGetClose) (catchAll (fun _ => pure ()) passthroughHandler).onRequest
    fun response => do
      assertStatus response "HTTP/1.1 200"
      assertContains response "ok"

def onErrorCalledTest : IO Unit := do
  let seen ← IO.mkRef false
  let onError : IO.Error → Async Unit := fun _ => seen.set true
  discard <| check "onError runs on failure" (mkGetClose) (catchAll onError throwingHandler).onRequest
    fun response => assertStatus response "HTTP/1.1 500"
  unless (← seen.get) do
    throw <| IO.userError "expected onError to run"

/-- Whatever the thrown message says, the response is always exactly `500` with the fixed body
`"Internal Server Error"` -- the original message never leaks into what the client sees. Checked
against a handful of varied messages (empty, long, containing the fixed response text itself,
punctuation/unicode), not just the single `"boom"` `caughtErrorTest` already covers. -/
def errorMessageNeverLeaksTest : IO Unit := do
  let messages :=
    [ "", "boom", String.ofList (List.replicate 5000 'x'), "Internal Server Error",
      "{\"secret\": \"leaked\"}", "unicode: 日本語 ✅", "line1\nline2\ttabbed" ]
  for msg in messages do
    let handler : StatelessHandler := { onRequest := fun _ => throw (IO.Error.userError msg) }
    check s!"thrown message {msg.quote} never leaks" (mkGetClose)
      (catchAll (fun _ => pure ()) handler).onRequest fun response => do
        assertStatus response "HTTP/1.1 500"
        assertContains response "Internal Server Error"
        if msg != "" && msg != "Internal Server Error" then
          assertAbsent response msg

def run : IO Unit :=
  runGroup "Middleware.CatchAll" do
    caughtErrorTest
    passthroughTest
    onErrorCalledTest
    errorMessageNeverLeaksTest

end Tests.CatchAll
