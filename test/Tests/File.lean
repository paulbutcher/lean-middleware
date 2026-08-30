/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import Middleware.File
public import Middleware.NotModified
public import Std.Http.Test.Helpers

public section

open Std.Http
open Std.Http.Server
open Std.Http.Internal.Test
open Std.Async
open Middleware (file notModified)

namespace Tests.File

/--
The safety argument for `Middleware.File.joinSafeSegments`, and the reason `file` can serve a
path built from a URL without a separate containment check afterwards: the join succeeds only
when every segment going into it was safe, and when it does succeed it produces nothing beyond
those segments joined by `/`. A path traversal would need either an unsafe segment to survive or
an extra component to appear from somewhere, and this rules out both.

For any segment array and any candidate `result`, the join equals `some result` exactly when two
things hold together: every `s` in `segments` answers `true` to `isSafeSegment` (not empty, not
`.` or `..`, and containing no `/` or NUL), and `result` is literally
`String.intercalate "/" segments.toList`. Being an `iff` rather than an implication is what makes
the second half exhaustive: it forbids any other string being returned, not merely asserting that
this one is. It says nothing about percent-encoded segments, which `isSafeSegment`'s own
documentation flags as needing to be decoded before they reach here.
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

/--
The failing direction stated directly: one bad segment anywhere is enough to defeat the whole
join. `joinSafeSegments_eq_some_iff` already implies this, but a caller reasoning about an attack
wants the contrapositive in the form the attack takes, namely a single hostile component among
otherwise ordinary ones.

For any segment array containing some `s` for which `isSafeSegment` answers `false`, the join
returns `none`. The membership hypothesis carries no position, so the segment's place in the
array is irrelevant, and no combination of surrounding safe segments can rescue it.
-/
theorem joinSafeSegments_eq_none_of_mem_unsafe (segments : Array String) (s : String)
    (hm : s ∈ segments) (hs : Middleware.File.isSafeSegment s = false) :
    Middleware.File.joinSafeSegments segments = none := by
  have hnot : ¬ (segments.all Middleware.File.isSafeSegment = true) := by
    intro hall
    simp [Array.all_eq_true_iff_forall_mem.mp hall s hm] at hs
  simp [Middleware.File.joinSafeSegments, hnot]

/--
The specific case worth naming, since it is the classic traversal: a `..` anywhere in the
segments defeats the join outright, whatever surrounds it. Stating it separately means a reader
checking this codebase against the attack does not have to unfold `isSafeSegment` to confirm it
is covered.

For any segment array with `".."` among its members, the join returns `none`. It follows from
`joinSafeSegments_eq_none_of_mem_unsafe` with `isSafeSegment ".."` discharged by `rfl`, so the
step from "`..` is a member" to "the join fails" rests on computation, not on a further
assumption.
-/
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

/-- A fixture of `n` repetitions of a 10-byte line, long enough to span many chunks. -/
def repeated (n : Nat) : String :=
  String.join (List.replicate n "0123456789")

def streamOf (path : System.FilePath) (size : Nat) (chunkSize : UInt64) : IO ByteArray :=
  Async.block do
    let stream ← Middleware.File.streamFile path size chunkSize
    stream.readAll

/-- Reassembly across chunk boundaries: the byte count the loop is bounded by must not stop it
before the file's last byte, however many reads that takes. -/
def streamsAcrossChunkBoundariesTest : IO Unit :=
  withFixtureDir fun dir => do
    let path := dir / "big.txt"
    let contents := repeated 500
    IO.FS.writeFile path contents
    let md ← path.metadata
    let streamed ← streamOf path md.byteSize.toNat 64
    unless streamed == contents.toUTF8 do
      throw <| IO.userError s!"streamed {streamed.size} bytes, expected {contents.toUTF8.size}"

/-- The bound is what stops a file that has grown since it was measured, so such a file is served
truncated rather than streamed for as long as it keeps growing. -/
def growthBeyondMeasuredSizeIsTruncatedTest : IO Unit :=
  withFixtureDir fun dir => do
    let path := dir / "big.txt"
    let contents := repeated 500
    IO.FS.writeFile path contents
    let streamed ← streamOf path 10 64
    unless streamed.size < contents.toUTF8.size && contents.toUTF8.extract 0 streamed.size == streamed do
      throw <| IO.userError s!"expected a truncated prefix, got {streamed.size} bytes"

def run : IO Unit :=
  runGroup "Middleware.File" do
    servesExistingFileTest
    missingFileFallsThroughTest
    directoryFallsThroughTest
    traversalRejectedTest
    encodedTraversalRejectedTest
    composesWithNotModifiedTest
    streamsAcrossChunkBoundariesTest
    growthBeyondMeasuredSizeIsTruncatedTest

end Tests.File
