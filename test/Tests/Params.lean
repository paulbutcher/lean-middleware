/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import Middleware.Params
public import Std.Http.Test.Helpers
public import Plausible

public section

open Std.Http
open Std.Http.Server
open Std.Http.Internal.Test
open Middleware (params Params)

namespace Tests.Params

def formHeaders : String :=
  "Content-Type: application/x-www-form-urlencoded\x0d\nConnection: close\x0d\n"

/-- Renders the looked-up value between brackets, so that a present-but-empty value is
distinguishable from an absent one. -/
def echoParamHandler (key : String) : StatelessHandler :=
  { onRequest := fun req =>
      let value := ((req.extensions.get Params).bind (Params.get · key)).getD "<missing>"
      Response.ok |>.text s!"[{value}]" }

def queryParamTest : IO Unit :=
  check "query param is extracted" (mkGetClose "/greet?name=world")
    (params (echoParamHandler "name")).onRequest fun response =>
      assertContains response "[world]"

def formParamTest : IO Unit :=
  check "form-urlencoded body param is extracted"
    (mkPost "/greet" "name=world" formHeaders)
    (params (echoParamHandler "name")).onRequest fun response =>
      assertContains response "[world]"

def formOverridesQueryTest : IO Unit :=
  check "form param takes precedence over query param"
    (mkPost "/greet?name=query" "name=form" formHeaders)
    (params (echoParamHandler "name")).onRequest fun response => do
      assertContains response "[form]"
      assertAbsent response "query"

def bodyStillReadableAfterParamsTest : IO Unit :=
  check "downstream handler can still read the body after params runs"
    (mkPost "/echo" "name=world" formHeaders)
    (params { onRequest := echoHandler }).onRequest fun response =>
      assertContains response "name=world"

/-- Posts `spelling=on` and looks the field up under `name`, which `spelling` percent-decodes to.
Browsers encode form field names far more aggressively than the `EncodedQueryParam` encoder does,
so a name arrives spelled in ways the sender never wrote. -/
def spellingTest (label spelling name : String) : IO Unit :=
  check s!"form field named {label} is found by its decoded name"
    (mkPost "/consent" s!"{spelling}=on&decision=allow" formHeaders)
    (params (echoParamHandler name)).onRequest fun response =>
      assertContains response "[on]"

def encodedFormNameTests : IO Unit := do
  spellingTest "approve-todos%3Aread" "approve-todos%3Aread" "approve-todos:read"
  spellingTest "approve-todos:read" "approve-todos:read" "approve-todos:read"
  spellingTest "a%20b" "a%20b" "a b"
  -- A literal space is not a valid encoded query character, so `a b` has no third, unencoded
  -- spelling on the wire; `a+b` is how a browser writes it.
  spellingTest "a+b" "a+b" "a b"

def encodedQueryNameTest : IO Unit :=
  check "query-string param posted percent-encoded is found by its decoded name"
    (mkGetClose "/consent?approve-todos%3Aread=on")
    (params (echoParamHandler "approve-todos:read")).onRequest fun response =>
      assertContains response "[on]"

def valuelessNameTest : IO Unit :=
  check "a name present with no value reads as an empty value, not as absent"
    (mkPost "/consent" "flag&decision=allow" formHeaders)
    (params (echoParamHandler "flag")).onRequest fun response =>
      assertContains response "[]"

/-- Encodes `(k{keyNum}, valueNum)` and `(k{otherKeyNum}, otherValueNum)` as a query string and
parses the result as a form body, checking both values come back unchanged. -/
def roundtripHolds (keyNum valueNum otherKeyNum otherValueNum : Nat) : Bool :=
  let key := s!"k{keyNum}"
  let otherKey := s!"k{otherKeyNum}"
  let value := toString valueNum
  let otherValue := toString otherValueNum
  let query := (URI.Query.empty.insert key value).insert otherKey otherValue
  let parsed := Middleware.ContentType.FormUrlEncoded.parse (URI.Query.toRawString query)
  let p : Params := { form := parsed }
  p.get key == some value && p.get otherKey == some otherValue

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

def hexByte (b : UInt8) : String :=
  let digits := String.ofList (Nat.toDigits 16 b.toNat)
  if digits.length == 1 then "0" ++ digits else digits

/-- Percent-encodes as a browser does when serialising `application/x-www-form-urlencoded`: the
URL Standard's safe set is `A-Za-z0-9*-._`, space becomes `+`, and everything else, `:` and `&`
and `=` included, becomes a percent triplet. This is deliberately more aggressive than
`EncodedQueryParam.encode`, which is what makes the two spellings of a name diverge. -/
def formEncode (s : String) : String :=
  s.foldl (init := "") fun acc c =>
    if c.isAlphanum || c == '*' || c == '-' || c == '.' || c == '_' then acc.push c
    else if c == ' ' then acc.push '+'
    else acc ++ String.join (c.toString.toUTF8.toList.map fun b => "%" ++ hexByte b)

def awkwardChars : Array Char := #[':', ' ', '+', '&', '=', '@', '/', '?', ';', ',']

/-- Builds a field name from `seed` out of characters a browser percent-encodes but
`EncodedQueryParam.encode` leaves alone (or, for `&` and `=`, that this library's own body parser
treats as separators when unencoded). Distinct seeds give distinct names. -/
def awkwardName (seed : Nat) : String :=
  "field" ++ String.ofList ((Nat.toDigits 10 seed).map fun d =>
    awkwardChars.getD (d.toNat - '0'.toNat) 'x')

def browserRoundtripHolds (nameSeed valueSeed : Nat) : Bool :=
  let name := awkwardName nameSeed
  let value := awkwardName valueSeed
  let body := formEncode name ++ "=" ++ formEncode value
  let p : Params := { form := Middleware.ContentType.FormUrlEncoded.parse body }
  p.get name == some value

/-- For any field name and value built from characters a browser encodes, posting the pair the way
a browser writes it and looking the field up by the name the markup gave it recovers the value.
The claim is about pure total functions, but the strongest form it admits here is a property: it
rests on `EncodedQueryParam.decode` inverting the encoding, and `Std.Http` offers no round-trip
lemma to build a proof on. -/
def browserRoundtripTest : IO Unit := do
  match ← Plausible.Testable.checkIO
      (Plausible.NamedBinder "nameSeed" <| ∀ nameSeed : Nat,
       Plausible.NamedBinder "valueSeed" <| ∀ valueSeed : Nat,
       browserRoundtripHolds nameSeed valueSeed = true) with
  | .success _ => pure ()
  | .gaveUp n => throw <| IO.userError s!"gave up after {n} tries without satisfying the guard"
  | .failure _ steps _ => throw <| IO.userError s!"counter-example found: {steps}"

def run : IO Unit :=
  runGroup "Middleware.Params" do
    queryParamTest
    formParamTest
    formOverridesQueryTest
    bodyStillReadableAfterParamsTest
    encodedFormNameTests
    encodedQueryNameTest
    valuelessNameTest
    roundtripTest
    browserRoundtripTest

end Tests.Params
