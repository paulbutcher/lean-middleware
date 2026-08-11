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

def run : IO Unit :=
  runGroup "Middleware.CatchAll" do
    caughtErrorTest
    passthroughTest
    onErrorCalledTest

end Tests.CatchAll
