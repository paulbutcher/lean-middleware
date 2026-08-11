/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Middleware.Params
import Std.Http.Test.Helpers
import Plausible

open Std.Http
open Std.Http.Server
open Std.Http.Internal.Test
open Middleware (params Params)

namespace Tests.Params

def echoParamHandler (key : String) : StatelessHandler :=
  { onRequest := fun req =>
      let value := ((req.extensions.get Params).bind (Params.get · key)).getD "<missing>"
      Response.ok |>.text value }

def queryParamTest : IO Unit :=
  check "query param is extracted" (mkGetClose "/greet?name=world")
    (params (echoParamHandler "name")).onRequest fun response =>
      assertContains response "world"

def formParamTest : IO Unit :=
  check "form-urlencoded body param is extracted"
    (mkPost "/greet" "name=world" "Content-Type: application/x-www-form-urlencoded\x0d\nConnection: close\x0d\n")
    (params (echoParamHandler "name")).onRequest fun response =>
      assertContains response "world"

def formOverridesQueryTest : IO Unit :=
  check "form param takes precedence over query param"
    (mkPost "/greet?name=query" "name=form"
      "Content-Type: application/x-www-form-urlencoded\x0d\nConnection: close\x0d\n")
    (params (echoParamHandler "name")).onRequest fun response => do
      assertContains response "form"
      assertAbsent response "query"

def bodyStillReadableAfterParamsTest : IO Unit :=
  check "downstream handler can still read the body after params runs"
    (mkPost "/echo" "name=world" "Content-Type: application/x-www-form-urlencoded\x0d\nConnection: close\x0d\n")
    (params { onRequest := echoHandler }).onRequest fun response =>
      assertContains response "name=world"

/-- Encodes `(k{keyNum}, valueNum)` and `(k{otherKeyNum}, otherValueNum)` as a query string and
parses the result as a form body, checking both values come back unchanged. -/
def roundtripHolds (keyNum valueNum otherKeyNum otherValueNum : Nat) : Bool :=
  let key := s!"k{keyNum}"
  let otherKey := s!"k{otherKeyNum}"
  let value := toString valueNum
  let otherValue := toString otherValueNum
  let query := (URI.Query.empty.insert key value).insert otherKey otherValue
  let parsed := Middleware.ContentType.FormUrlEncoded.parse (URI.Query.toRawString query)
  parsed.get key == some value && parsed.get otherKey == some otherValue

/-- For any two distinct numeric keys and arbitrary numeric values, encoding as a query string
and parsing as a form body recovers each original value. Guards against off-by-one bugs in the
`&`/`=` splitting logic and against fields clobbering each other. -/
def roundtripTest : IO Unit := do
  match ← Plausible.Testable.checkIO
      (Plausible.NamedBinder "keyNum" <| ∀ keyNum : Nat,
       Plausible.NamedBinder "valueNum" <| ∀ valueNum : Nat,
       Plausible.NamedBinder "otherKeyNum" <| ∀ otherKeyNum : Nat,
       Plausible.NamedBinder "otherValueNum" <| ∀ otherValueNum : Nat,
       keyNum ≠ otherKeyNum → roundtripHolds keyNum valueNum otherKeyNum otherValueNum = true) with
  | .success _ => pure ()
  | .gaveUp n => throw <| IO.userError s!"gave up after {n} tries without satisfying the guard"
  | .failure _ steps _ => throw <| IO.userError s!"counter-example found: {steps}"

def run : IO Unit :=
  runGroup "Middleware.Params" do
    queryParamTest
    formParamTest
    formOverridesQueryTest
    bodyStillReadableAfterParamsTest
    roundtripTest

end Tests.Params
