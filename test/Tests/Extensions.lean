/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import Middleware.Extensions
public import Middleware.Params
public import Std.Http.Test.Helpers

public section

open Std.Http
open Std.Http.Server
open Std.Http.Internal.Test
open Middleware (params Params requiring)

namespace Tests.Extensions

/-- Reports the parameters it was handed, recording in `entered` that it ran at all. A `500`
raised by the combinator and a `500` the handler itself chose look identical from the outside;
only the flag tells them apart. -/
def reportParams (entered : IO.Ref Bool) : StatelessHandler :=
  { onRequest := requiring fun (ps : Params) _ => do
      entered.set true
      Response.ok.text s!"{ps.get "title" |>.getD "<absent>"}/{ps.get "note" |>.getD "<absent>"}" }

def formPost (body : String) : String :=
  mkPost "/" body "Content-Type: application/x-www-form-urlencoded\x0d\nConnection: close\x0d\n"

def seesParametersTest : IO Unit := do
  let entered ← IO.mkRef false
  check "requiring hands the handler the parsed parameters"
    (formPost "title=hello&other=x") (params (reportParams entered)).onRequest fun response => do
      assertStatus response "HTTP/1.1 200"
      assertContains response "hello/<absent>"
  unless ← entered.get do
    throw <| IO.userError "expected the wrapped handler to run"

/-- The case the combinator exists for: an empty form is an ordinary request, and reaches the
handler, whereas the same emptiness read out of a missing extension would not. -/
def emptyFormStillReachesHandlerTest : IO Unit := do
  let entered ← IO.mkRef false
  check "requiring runs on an empty form, reporting absent parameters"
    (formPost "") (params (reportParams entered)).onRequest fun response => do
      assertStatus response "HTTP/1.1 200"
      assertContains response "<absent>/<absent>"
  unless ← entered.get do
    throw <| IO.userError "expected the wrapped handler to run"

def refusesWithoutMiddlewareTest : IO Unit := do
  let entered ← IO.mkRef false
  check "requiring answers 500 when `params` isn't in the stack"
    (formPost "title=hello") (reportParams entered).onRequest fun response =>
      assertStatus response "HTTP/1.1 500"
  if ← entered.get then
    throw <| IO.userError "expected the wrapped handler not to run at all"

def customMissingHandlerTest : IO Unit := do
  let entered ← IO.mkRef false
  let missing : StatelessHandler :=
    { onRequest := fun _ => Response.serviceUnavailable.text "stack-misconfigured" }
  let handler : StatelessHandler :=
    { onRequest := requiring (missing := missing) fun (ps : Params) _ => do
        entered.set true
        Response.ok.text (ps.get "title" |>.getD "<absent>") }
  check "a supplied `missing` handler replaces the default 500"
    (formPost "title=hello") handler.onRequest fun response => do
      assertStatus response "HTTP/1.1 503"
      assertContains response "stack-misconfigured"
  if ← entered.get then
    throw <| IO.userError "expected the wrapped handler not to run at all"

def run : IO Unit :=
  runGroup "Middleware.Extensions" do
    seesParametersTest
    emptyFormStillReachesHandlerTest
    refusesWithoutMiddlewareTest
    customMissingHandlerTest

end Tests.Extensions
