/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import Middleware.HeaderValue
public import Std.Http.Test.Helpers
public import Plausible

public section

open Std.Http
open Std.Http.Internal.Test
open Middleware.Header.Value (ofStringSanitized)

namespace Tests.HeaderValue

/-- Sanitizing leaves alone anything `Header.Value.ofString?` would already have accepted, its own
output included. -/
def sanitizeHolds (s : String) : Bool :=
  let cleaned := (ofStringSanitized s).value
  (match Header.Value.ofString? s with
    | some v => cleaned == v.value
    | none => true)
  && (ofStringSanitized cleaned).value == cleaned

def sanitizeTest : IO Unit := do
  match ← Plausible.Testable.checkIO
      (Plausible.NamedBinder "s" <| ∀ s : String, sanitizeHolds s = true) with
  | .success _ => pure ()
  | .gaveUp n => throw <| IO.userError s!"gave up after {n} tries"
  | .failure _ steps _ => throw <| IO.userError s!"counter-example found: {steps}"

/-- The same property against values a real response carries, since `Plausible` is unlikely to
generate a string `Header.Value.ofString?` accepts in the first place. -/
def realValuesUnchangedTest : IO Unit := do
  let values :=
    [ "text/html; charset=utf-8", "max-age=31536000; includeSubDomains", "1; mode=block",
      "W/\"abc123\"", "sid=a%20b; Path=/; HttpOnly; SameSite=Lax",
      "Mon, 02 Jan 2026 15:04:05 GMT", "https://example.com/a/b?c=d", "*" ]
  for value in values do
    unless (ofStringSanitized value).value == value do
      throw <| IO.userError
        s!"{value.quote} came back as {(ofStringSanitized value).value.quote}"

def sanitizedCases : List (String × String) :=
  [ ("plain", "plain"),
    ("split\x0d\nX-Evil: 1", "splitX-Evil: 1"),
    ("  padded  ", "padded"),
    ("\tleading and trailing tabs\t", "leading and trailing tabs"),
    ("interior\ttab", "interior\ttab"),
    ("\x00\x7f", "") ]

def sanitizedTest : IO Unit := do
  for (input, expected) in sanitizedCases do
    let got := (ofStringSanitized input).value
    unless got == expected do
      throw <| IO.userError s!"{input.quote} sanitized to {got.quote}, expected {expected.quote}"

def run : IO Unit :=
  runGroup "Middleware.Header.Value" do
    sanitizeTest
    realValuesUnchangedTest
    sanitizedTest

end Tests.HeaderValue
