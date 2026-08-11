/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Middleware.File
import Middleware.NotModified
import Std.Http.Test.Helpers
import Plausible

open Std.Http
open Std.Http.Server
open Std.Http.Internal.Test
open Middleware (file notModified)

namespace Tests.File

/--
The safety argument for `Middleware.File.joinSafeSegments`: whenever it succeeds, every segment
that went into it was safe, and the result is exactly their `/`-intercalation, nothing more.
Combined with `isSafeSegment`'s definition (no segment is `.`/`..`, none contains a separator or
NUL), this means the joined string can never be interpreted as escaping above the root or
introducing extra path components that weren't present as their own segment.
-/
theorem joinSafeSegments_eq (segments : Array String) (result : String)
    (h : Middleware.File.joinSafeSegments segments = some result) :
    (∀ s ∈ segments, Middleware.File.isSafeSegment s = true) ∧
      result = String.intercalate "/" segments.toList := by
  unfold Middleware.File.joinSafeSegments at h
  split at h
  · rename_i hall
    exact ⟨Array.all_eq_true_iff_forall_mem.mp hall, (Option.some.injEq _ _).mp h |>.symm⟩
  · cases h

def notFoundHandler : StatelessHandler :=
  { onRequest := fun _ => Response.notFound |>.text "not found" }

/-- Creates a temp directory with a `hello.txt` fixture, runs `act`, then removes the directory. -/
def withFixtureDir (act : System.FilePath → IO Unit) : IO Unit := do
  let dir ← IO.FS.createTempDir
  try
    IO.FS.writeFile (dir / "hello.txt") "hello world"
    act dir
  finally
    IO.FS.removeDirAll dir

def servesExistingFileTest : IO Unit :=
  withFixtureDir fun dir => do
    let stack := file dir notFoundHandler
    check "serves an existing file" (mkGetClose "/hello.txt") stack.onRequest fun response => do
      assertStatus response "HTTP/1.1 200"
      assertContains response "hello world"
      assertContains response "Etag"
      assertContains response "Last-Modified"

def missingFileFallsThroughTest : IO Unit :=
  withFixtureDir fun dir => do
    let stack := file dir notFoundHandler
    check "missing file falls through to inner handler" (mkGetClose "/nope.txt")
      stack.onRequest fun response => do
        assertStatus response "HTTP/1.1 404"
        assertContains response "not found"

def directoryFallsThroughTest : IO Unit :=
  withFixtureDir fun dir => do
    let stack := file dir notFoundHandler
    check "a directory falls through rather than being served" (mkGetClose "/")
      stack.onRequest fun response => assertStatus response "HTTP/1.1 404"

/-- The concrete regression test paired with `joinSafeSegments_eq`: a traversal attempt must
never escape the served root, whether written as a literal `..` or percent-encoded. -/
def traversalRejectedTest : IO Unit :=
  withFixtureDir fun dir => do
    let stack := file dir notFoundHandler
    check "literal .. traversal falls through instead of serving a host file"
      (mkGetClose "/../../../../../../etc/passwd") stack.onRequest fun response =>
        assertStatus response "HTTP/1.1 404"

def encodedTraversalRejectedTest : IO Unit :=
  withFixtureDir fun dir => do
    let stack := file dir notFoundHandler
    check "percent-encoded .. traversal falls through too"
      (mkGetClose "/%2e%2e/%2e%2e/%2e%2e/%2e%2e/%2e%2e/%2e%2e/etc/passwd") stack.onRequest fun response =>
        assertStatus response "HTTP/1.1 404"

def composesWithNotModifiedTest : IO Unit :=
  withFixtureDir fun dir => do
    let stack := notModified (file dir notFoundHandler)
    check "file composed with notModified still serves normally when uncached" (mkGetClose "/hello.txt")
      stack.onRequest fun response => do
        assertStatus response "HTTP/1.1 200"
        assertContains response "hello world"
        assertContains response "Etag"

/-- Appending a `..` segment always defeats `joinSafeSegments`, regardless of what precedes it. -/
def containsDotDotAlwaysRejectedTest : IO Unit := do
  match ← Plausible.Testable.checkIO
      (Plausible.NamedBinder "segments" <| ∀ segments : List String,
        Middleware.File.joinSafeSegments (segments ++ [".."]).toArray = none) with
  | .success _ => pure ()
  | .gaveUp n => throw <| IO.userError s!"gave up after {n} tries without satisfying the guard"
  | .failure _ steps _ => throw <| IO.userError s!"counter-example found: {steps}"

def roundtripHolds (n : Nat) : Bool :=
  match Middleware.File.joinSafeSegments #["seg", toString n] with
  | some result => result == s!"seg/{n}"
  | none => false

/-- Two safe segments always join to exactly their `/`-intercalation. -/
def roundtripTest : IO Unit := do
  match ← Plausible.Testable.checkIO (Plausible.NamedBinder "n" <| ∀ n : Nat, roundtripHolds n = true) with
  | .success _ => pure ()
  | .gaveUp n => throw <| IO.userError s!"gave up after {n} tries"
  | .failure _ steps _ => throw <| IO.userError s!"counter-example found: {steps}"

def run : IO Unit :=
  runGroup "Middleware.File" do
    servesExistingFileTest
    missingFileFallsThroughTest
    directoryFallsThroughTest
    traversalRejectedTest
    encodedTraversalRejectedTest
    composesWithNotModifiedTest
    containsDotDotAlwaysRejectedTest
    roundtripTest

end Tests.File
