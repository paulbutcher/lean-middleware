/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Middleware.NotModified
import Std.Http.Test.Helpers
import Plausible

open Std.Http
open Std.Http.Server
open Std.Http.Internal.Test
open Middleware (notModified ETag LastModified)

namespace Tests.NotModified

def resourceTimestamp : Std.Time.Timestamp :=
  .ofSecondsSinceUnixEpoch (.ofNat 1_000_000_000)

def earlierTimestamp : Std.Time.Timestamp :=
  .ofSecondsSinceUnixEpoch (.ofNat 900_000_000)

def laterTimestamp : Std.Time.Timestamp :=
  .ofSecondsSinceUnixEpoch (.ofNat 1_100_000_000)

def dateAt (t : Std.Time.Timestamp) : Std.Time.DateTime :=
  .ofTimestampWithZone t Std.Time.TimeZone.UTC

def fixedETag : ETag := { value := "abc123", weak := false }

def fixedLastModified : LastModified := { date := dateAt resourceTimestamp }

/-- Always responds 200 "hello" with a fixed ETag and Last-Modified, as `file` would. -/
def baseHandler : StatelessHandler :=
  { onRequest := fun _ => do
      let resp ← Response.ok |>.text "hello"
      let (etagName, etagValue) := ETag.serialize fixedETag
      let (lmName, lmValue) := LastModified.serialize fixedLastModified
      let headers := resp.line.headers.insert etagName etagValue |>.insert lmName lmValue
      pure ({ resp with line := { resp.line with headers } } : Response Body.Any) }

def stack : StatelessHandler := notModified baseHandler

def etagMatchTest : IO Unit :=
  check "matching If-None-Match becomes 304"
    (mkGet "/" "If-None-Match: \"abc123\"\x0d\nConnection: close\x0d\n")
    stack.onRequest fun response => do
      assertStatus response "HTTP/1.1 304"
      assertAbsent response "hello"

def etagMismatchTest : IO Unit :=
  check "mismatching If-None-Match passes through as 200"
    (mkGet "/" "If-None-Match: \"other\"\x0d\nConnection: close\x0d\n")
    stack.onRequest fun response => do
      assertStatus response "HTTP/1.1 200"
      assertContains response "hello"

def ifModifiedSinceEarlierTest : IO Unit :=
  check "If-Modified-Since older than Last-Modified stays 200"
    (mkGet "/" s!"If-Modified-Since: {(dateAt earlierTimestamp).toRFC822String}\x0d\nConnection: close\x0d\n")
    stack.onRequest fun response => do
      assertStatus response "HTTP/1.1 200"
      assertContains response "hello"

def ifModifiedSinceLaterTest : IO Unit :=
  check "If-Modified-Since at or after Last-Modified becomes 304"
    (mkGet "/" s!"If-Modified-Since: {(dateAt laterTimestamp).toRFC822String}\x0d\nConnection: close\x0d\n")
    stack.onRequest fun response => do
      assertStatus response "HTTP/1.1 304"
      assertAbsent response "hello"

def ifNoneMatchPrecedenceTest : IO Unit :=
  check "mismatching If-None-Match wins over a satisfied If-Modified-Since"
    (mkGet "/"
      s!"If-None-Match: \"other\"\x0d\nIf-Modified-Since: {(dateAt laterTimestamp).toRFC822String}\x0d\nConnection: close\x0d\n")
    stack.onRequest fun response => do
      assertStatus response "HTTP/1.1 200"
      assertContains response "hello"

/-- Two `ETag`s with the same `value` always match under weak comparison, regardless of either
side's `weak` flag -- that's the entire point of weak comparison (RFC 9110 §8.8.3.2). -/
def weakMatchIgnoresWeakFlagHolds (value : String) (w1 w2 : Bool) : Bool :=
  ETag.weakMatches { value, weak := w1 } { value, weak := w2 } == true

def weakMatchIgnoresWeakFlagTest : IO Unit := do
  match ← Plausible.Testable.checkIO
      (Plausible.NamedBinder "value" <| ∀ value : String,
       Plausible.NamedBinder "w1" <| ∀ w1 : Bool,
       Plausible.NamedBinder "w2" <| ∀ w2 : Bool,
       weakMatchIgnoresWeakFlagHolds value w1 w2 = true) with
  | .success _ => pure ()
  | .gaveUp n => throw <| IO.userError s!"gave up after {n} tries"
  | .failure _ steps _ => throw <| IO.userError s!"counter-example found: {steps}"

/-- Two `ETag`s with different `value`s never match, regardless of `weak` flags. -/
def weakMatchDistinguishesValuesHolds (v1 v2 : String) : Bool :=
  ETag.weakMatches { value := v1 } { value := v2 } == false

def weakMatchDistinguishesValuesTest : IO Unit := do
  match ← Plausible.Testable.checkIO
      (Plausible.NamedBinder "v1" <| ∀ v1 : String,
       Plausible.NamedBinder "v2" <| ∀ v2 : String,
       v1 ≠ v2 → weakMatchDistinguishesValuesHolds v1 v2 = true) with
  | .success _ => pure ()
  | .gaveUp n => throw <| IO.userError s!"gave up after {n} tries without satisfying the guard"
  | .failure _ steps _ => throw <| IO.userError s!"counter-example found: {steps}"

def run : IO Unit :=
  runGroup "Middleware.NotModified" do
    etagMatchTest
    etagMismatchTest
    ifModifiedSinceEarlierTest
    ifModifiedSinceLaterTest
    ifNoneMatchPrecedenceTest
    weakMatchIgnoresWeakFlagTest
    weakMatchDistinguishesValuesTest

end Tests.NotModified
