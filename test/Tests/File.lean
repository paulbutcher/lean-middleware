/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Middleware.File
import Middleware.NotModified
import Std.Http.Test.Helpers

open Std.Http
open Std.Http.Server
open Std.Http.Internal.Test
open Middleware (file notModified)

namespace Tests.File

/--
The safety argument for `Middleware.File.joinSafeSegments`: it succeeds exactly when every
segment that went into it was safe, and then the result is exactly their `/`-intercalation,
nothing more. Combined with `isSafeSegment`'s definition (no segment is `.`/`..`, none contains a
separator or NUL), this means the joined string can never be interpreted as escaping above the
root or introducing extra path components that weren't present as their own segment.
-/
theorem joinSafeSegments_eq_some_iff (segments : Array String) (result : String) :
    Middleware.File.joinSafeSegments segments = some result ↔
      (∀ s ∈ segments, Middleware.File.isSafeSegment s = true) ∧
        result = String.intercalate "/" segments.toList := by
  unfold Middleware.File.joinSafeSegments
  constructor
  · intro h
    split at h
    · rename_i hall
      exact ⟨Array.all_eq_true_iff_forall_mem.mp hall, (Option.some.injEq _ _).mp h |>.symm⟩
    · cases h
  · rintro ⟨hall, rfl⟩
    rw [if_pos (Array.all_eq_true_iff_forall_mem.mpr hall)]

theorem joinSafeSegments_eq_none_of_mem_unsafe (segments : Array String) (s : String)
    (hm : s ∈ segments) (hs : Middleware.File.isSafeSegment s = false) :
    Middleware.File.joinSafeSegments segments = none := by
  have hnot : ¬ (segments.all Middleware.File.isSafeSegment = true) := by
    intro hall
    simp [Array.all_eq_true_iff_forall_mem.mp hall s hm] at hs
  simp [Middleware.File.joinSafeSegments, hnot]

/-- A `..` anywhere in the segments defeats the join outright, whatever surrounds it. -/
theorem joinSafeSegments_eq_none_of_dotdot (segments : Array String) (h : ".." ∈ segments) :
    Middleware.File.joinSafeSegments segments = none :=
  joinSafeSegments_eq_none_of_mem_unsafe segments ".." h rfl

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

/-- The concrete regression test paired with `joinSafeSegments_eq_none_of_dotdot`: a traversal
attempt must never escape the served root, whether written as a literal `..` or percent-encoded.
-/
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

def run : IO Unit :=
  runGroup "Middleware.File" do
    servesExistingFileTest
    missingFileFallsThroughTest
    directoryFallsThroughTest
    traversalRejectedTest
    encodedTraversalRejectedTest
    composesWithNotModifiedTest

end Tests.File
