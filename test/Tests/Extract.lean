/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import Middleware.Extract
public import Std.Http.Test.Helpers

public section

open Std.Http
open Std.Http.Server
open Std.Http.Internal.Test
open Middleware

namespace Tests.Extract

/-- An extractor that records that it ran, so a test can show a refusal before it stopped it. -/
def marking (ran : IO.Ref Bool) : Extractor Unit := do
  (ran.set true : IO Unit)

def formPost (body : String) : String :=
  mkPost "/" body "Content-Type: application/x-www-form-urlencoded\x0d\nConnection: close\x0d\n"

/-- An application's own extractor, built from the library's with `do`. -/
def shouted (name : String) : Extractor String :=
  return (← Extract.field name).toUpper

def bindsInOrderTest : IO Unit := do
  let handler : StatelessHandler :=
    { onRequest := extract (key ← Extract.field "key") (value ← Extract.field key)
        (loud ← shouted "title") =>
        fun _ => Response.ok.text s!"{key}={value} {loud}" }
  check "each extractor sees the ones before it, and the body sees them all"
    (formPost "key=colour&colour=red&title=hi") (params handler).onRequest fun response => do
      assertStatus response "HTTP/1.1 200"
      assertContains response "colour=red HI"

def missingFieldTest : IO Unit := do
  let ran ← IO.mkRef false
  let handler : StatelessHandler :=
    { onRequest := extract (title ← Extract.field "title") (_ ← marking ran) =>
        fun _ => Response.ok.text title }
  check "a missing field answers 400 naming it"
    (formPost "other=x") (params handler).onRequest fun response => do
      assertStatus response "HTTP/1.1 400"
      assertContains response "`title`"
  if ← ran.get then
    throw <| IO.userError "expected the extractors after the refusal not to run"

def optionalFieldTest : IO Unit := do
  let handler : StatelessHandler :=
    { onRequest := extract (title ← Extract.field? "title") =>
        fun _ => Response.ok.text (title.getD "<absent>") }
  check "field? reports an absent field without refusing"
    (formPost "other=x") (params handler).onRequest fun response => do
      assertStatus response "HTTP/1.1 200"
      assertContains response "<absent>"

def fieldWithoutParamsTest : IO Unit := do
  let ran ← IO.mkRef false
  let handler : StatelessHandler :=
    { onRequest := extract (_ ← Extract.field? "title") (_ ← marking ran) =>
        fun _ => Response.ok.text "ran" }
  check "field? refuses as params does when `params` isn't in the stack"
    (formPost "title=hello") handler.onRequest fun response =>
      assertStatus response "HTTP/1.1 500"
  if ← ran.get then
    throw <| IO.userError "expected the extractors after the refusal not to run"

def customMissingTest : IO Unit := do
  let missing : StatelessHandler :=
    { onRequest := fun _ => Response.serviceUnavailable.text "stack-misconfigured" }
  let handler : StatelessHandler :=
    { onRequest := extract (_ ← Extract.flash (missing := missing)) =>
        fun _ => Response.ok.text "ran" }
  check "a supplied `missing` handler replaces the default 500" (mkGetClose "/")
    handler.onRequest fun response => do
      assertStatus response "HTTP/1.1 503"
      assertContains response "stack-misconfigured"

/-- A request with no flash message still carries a `Flash`, so it is served, not refused. -/
def flashPresentButEmptyTest : IO Unit := do
  let store ← MemoryStore.new
  let handler : StatelessHandler :=
    { onRequest := extract (f ← Extract.flash) (_ ← Extract.session) (_ ← Extract.cookies) =>
        fun _ => Response.ok.text (f.message.getD "<no message>") }
  check "Extract.flash runs for a request carrying no flash message" (mkGetClose "/")
    (cookies (session store {} (flash handler))).onRequest fun response => do
      assertStatus response "HTTP/1.1 200"
      assertContains response "<no message>"

def run : IO Unit :=
  runGroup "Middleware.Extract" do
    bindsInOrderTest
    missingFieldTest
    optionalFieldTest
    fieldWithoutParamsTest
    customMissingTest
    flashPresentButEmptyTest

end Tests.Extract
