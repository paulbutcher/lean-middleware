/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import Middleware.CacheControl
public import Middleware.File
public import Middleware.NotModified
public import Leancrypto

public section

open Std.Http
open Routing

namespace Middleware.Assets

/-- The path an application asks for, the path that content is served under, the digest that
distinguishes it, and where the bytes are. -/
structure Entry where
  logical : String
  served : String
  hash : String
  file : System.FilePath

/-- How much of the digest goes in the path: enough to separate one revision of an asset from
another, short enough to keep URLs readable. The naming is reproducible outside Lean, for a build
step that uploads the same files elsewhere: lowercase hex of the file's SHA-256, cut to this many
characters, placed before the final extension. -/
def fingerprintLength : Nat := 16

private def digestOf (bytes : ByteArray) : String :=
  Leancrypto.Codec.Hex.encodeString (Leancrypto.Sha256.hash bytes)

private def insertHash (name hash : String) : String :=
  match (name.splitOn ".").reverse with
  | [] => name
  | [_] => s!"{name}.{hash}"
  | ext :: revStem => String.intercalate "." (revStem.reverse ++ [hash, ext])

/-- Places the digest in the final path segment, so that a directory name containing a `.` isn't
mistaken for the extension. -/
private def fingerprint (logical hash : String) : String :=
  match (logical.splitOn "/").reverse with
  | [] => logical
  | name :: revDirs => String.intercalate "/" (revDirs.reverse ++ [insertHash name hash])

private def relativeTo (root path : System.FilePath) : Option String :=
  let rootStr := root.toString
  let pathStr := path.toString
  if rootStr.isPrefixOf pathStr then
    let rest := (pathStr.drop rootStr.length).toString
    let rest := if rest.startsWith "/" then (rest.drop 1).toString else rest
    if rest.isEmpty then none else some rest
  else
    none

/-- The request path as a lookup key. Nothing built from it ever reaches the filesystem: it can
only select an entry `load` already established, so a `..` or a NUL fails to match and needs no
separate rejection. -/
private def requestKey (path : URI.Path) : String :=
  "/" ++ String.intercalate "/" path.toDecodedSegments.toList

end Middleware.Assets

namespace Middleware

/-- A fixed set of assets, each under a path carrying the digest of its content. Rendering a URL
and serving the bytes read the same entries, so the two cannot disagree about what an asset is
called; see the `path?_resolves` theorem in `Tests/Assets.lean`. -/
structure Assets where
  entries : Array Assets.Entry

namespace Assets

/-- The path to render for `logical`, or `none` if no such asset was loaded. `none` means the
application asked for something that isn't there, which is worth reporting rather than papering
over with the unfingerprinted path: that would serve stale bytes under a far-future policy. -/
@[expose] def path? (a : Assets) (logical : String) : Option String :=
  (a.entries.find? (·.logical == logical)).map (·.served)

/-- The entry to serve for a request path: the other half of the pair `path?_resolves` relates. -/
@[expose] def entry? (a : Assets) (served : String) : Option Entry :=
  a.entries.find? (·.served == served)

/--
Hashes every file under `root`, once. `walkDir` follows symlinks, so an entry is kept only when
it is still inside `root` after resolution, matching what `file` checks per request.
-/
def load (root : System.FilePath) : IO Assets := do
  let mut entries : Array Entry := #[]
  for path in ← root.walkDir do
    if ← path.isDir then
      continue
    let some logical := relativeTo root path | continue
    unless ← Middleware.File.isContainedIn root path do
      continue
    let hash := digestOf (← IO.FS.readBinFile path)
    entries := entries.push
      { logical,
        served := "/" ++ fingerprint logical (hash.take fingerprintLength).toString,
        hash,
        file := path }
  return { entries }

end Assets

/--
Serves the assets in `a` under their fingerprinted paths, falling through to the inner handler
for anything else, so plain `file` serving can sit inside it.

The far-future default is safe only because the path changes whenever the content does; it is
the reason this middleware sets the header itself rather than leaving it to `cacheControl`, whose
stack-wide policy has to suit everything else. As with `file`, `Content-Type` is left to
`contentType` composed outside, which still reads the extension a fingerprinted name keeps.
-/
def assets {e : Engine} [ServerEngine e] (a : Assets)
    (policy : CachePolicy := .maxAge 31536000 (immutable := true)) : Middleware e :=
  fun handler =>
    { handler with
      onRequest := fun req => do
        match a.entry? (Assets.requestKey req.line.uri.path) with
        | none => handler.onRequest req
        | some entry =>
          let md ← entry.file.metadata
          let etag : ETag := { value := entry.hash }
          let headers :=
            Headers.empty
              |>.insert (ETag.serialize etag).fst (ETag.serialize etag).snd
              |>.insert Header.Name.cacheControl
                  (Header.Value.ofStringSanitized policy.toWire)
          ServerEngine.stream { line := { status := .ok, headers } } none
            (File.streamFile entry.file md.byteSize.toNat) }

end Middleware
