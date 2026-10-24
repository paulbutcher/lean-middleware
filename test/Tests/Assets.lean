/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import MiddlewareAssets
public import RoutingStd
public import Std.Http.Test.Helpers

public section

open Std.Http
open Routing
open Std.Http.Internal.Test
open Middleware

namespace Tests.Assets

/--
Whatever an application renders, the stack can serve. This is the whole correctness argument for
handing one `Assets` to both: a rendered URL that nothing answers would be a broken page, and it
cannot arise, because the two halves read one array rather than deriving the name twice.

For any `Assets` value `a` and any strings `logical` and `served`, if `path?` answers
`some served` for `logical`, then `entry?` answers `some` for that same `served`. It is stated
over an arbitrary `a` rather than one `load` produced, so it holds however the entries were
assembled; and `isSome` is the right conclusion, because serving needs only that some entry
claims the path, not that it is the entry `path?` happened to find.
-/
theorem path?_resolves (a : Assets) (logical served : String)
    (h : a.path? logical = some served) : (a.entry? served).isSome := by
  simp only [Assets.path?, Assets.entry?, Option.map_eq_some_iff] at h ⊢
  obtain ⟨e, hfind, rfl⟩ := h
  rw [Array.isSome_find?, Array.any_eq_true]
  obtain ⟨i, hi, he⟩ := Array.getElem_of_mem (Array.mem_of_find?_eq_some hfind)
  exact ⟨i, hi, by simp [he]⟩

def notFoundHandler : StatelessHandler .std :=
  { onRequest := fun _ => Response.notFound |>.text "not found" }

def withStylesheet {α : Type} (contents : String) (act : System.FilePath → IO α) : IO α := do
  let dir ← IO.FS.createTempDir
  try
    IO.FS.createDirAll (dir / "css")
    IO.FS.writeFile (dir / "css" / "auth.css") contents
    act dir
  finally
    IO.FS.removeDirAll dir

def servedPath (a : Assets) : IO String :=
  match a.path? "css/auth.css" with
  | some served => pure served
  | none => throw <| IO.userError "expected a loaded asset to have a path"

def pathFor (contents : String) : IO String :=
  withStylesheet contents fun dir => do servedPath (← Assets.load dir)

def fingerprintsThePathTest : IO Unit := do
  let served ← pathFor "body { color: red }"
  unless served.startsWith "/css/auth." && served.endsWith ".css" do
    throw <| IO.userError s!"expected the digest inside the final segment, got {served.quote}"
  if served == "/css/auth.css" then
    throw <| IO.userError "expected the served path to differ from the logical one"

/-- The failure that motivates the package: an edited asset the browser keeps anyway. Under a
far-future policy nothing can dislodge the old copy, so a digest that didn't move with the
content would make the policy unsafe rather than merely unhelpful. -/
def editedContentMovesThePathTest : IO Unit := do
  let red ← pathFor "body { color: red }"
  let blue ← pathFor "body { color: blue }"
  if red == blue then
    throw <| IO.userError s!"expected differing content to move the path, both were {red.quote}"

def unknownAssetHasNoPathTest : IO Unit :=
  withStylesheet "body { color: red }" fun dir => do
    let a ← Assets.load dir
    if (a.path? "css/missing.css").isSome then
      throw <| IO.userError "expected an unloaded name to have no path, not a defaulted one"

def servesFingerprintedPathTest : IO Unit :=
  withStylesheet "body { color: red }" fun dir => do
    let a ← Assets.load dir
    check "serves what path? renders, cached far into the future" (mkGetClose (← servedPath a))
      ((assets a : Middleware .std) notFoundHandler).onRequest fun response => do
        assertStatus response "HTTP/1.1 200"
        assertContains response "body { color: red }"
        assertContains response "Cache-Control: public, max-age=31536000, immutable"
        assertContains response "Etag"

/-- Unfingerprinted paths have to fall through, or `file` couldn't sit inside this layer. -/
def plainPathFallsThroughTest : IO Unit :=
  withStylesheet "body { color: red }" fun dir => do
    let a ← Assets.load dir
    check "the unfingerprinted path falls through to the inner handler" (mkGetClose "/css/auth.css")
      ((assets a : Middleware .std) notFoundHandler).onRequest fun response =>
        assertStatus response "HTTP/1.1 404"

def run : IO Unit :=
  runGroup "Middleware.Assets" do
    fingerprintsThePathTest
    editedContentMovesThePathTest
    unknownAssetHasNoPathTest
    servesFingerprintedPathTest
    plainPathFallsThroughTest

end Tests.Assets
