/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import Middleware.Core
public import Middleware.NotModified

public section

open Std.Http
open Std.Http.Server
open Std.Async

namespace Middleware.File

/--
Whether `s` is safe to use as a single filesystem path component: non-empty, not `.`/`..`, and
free of path separators or NUL bytes.

Deliberately checked on decoded segments, not via `Std.Http.URI.Path.normalize`: `normalize`
collapses dot-segments by comparing each segment's *wire* (percent-encoded) form against the
literal strings `.`/`..`, so a percent-encoded `%2e%2e` sails through unnoticed and only becomes
a literal `..` when decoded afterwards, downstream of the check meant to catch it.
-/
@[expose] def isSafeSegment (s : String) : Bool :=
  !s.isEmpty && s != "." && s != ".." && s.toList.all (fun c => c != '/' && c != '\x00')

/--
Joins path segments into a root-relative path string, or `none` if any segment is unsafe (see
`isSafeSegment`). Safe by construction: whenever this succeeds, every segment that went into it
was safe, and the result is exactly their `/`-intercalation, nothing more -- see the
`joinSafeSegments_eq_some_iff` theorem in `Tests/File.lean` for the proof.
-/
@[expose] def joinSafeSegments (segments : Array String) : Option String :=
  if segments.all isSafeSegment then
    some (String.intercalate "/" segments.toList)
  else
    none

/--
Resolves a request path against `root`, or `none` if the path escapes `root` (via `joinSafeSegments`)
or resolution otherwise fails.
-/
def resolvePath (root : System.FilePath) (uriPath : URI.Path) : Option System.FilePath := do
  let rel ← joinSafeSegments uriPath.toDecodedSegments
  some (root / rel)

/--
Whether the real (symlink-resolved) path of `target` is still contained in the real path of
`root`. Defense in depth against a symlink inside the served directory pointing outside it, which
`joinSafeSegments`'s purely syntactic check can't see.
-/
def isContainedIn (root target : System.FilePath) : IO Bool := do
  let realRoot ← IO.FS.realPath root
  let realTarget ← IO.FS.realPath target
  return realRoot.toString.isPrefixOf realTarget.toString

/--
Streams a file's contents in `chunkSize`-byte pieces without buffering the whole file in memory.
`size` is the file's length as the caller measured it; a file that has grown since is truncated,
at the first chunk boundary at or past `size`.

`size` is also what bounds the read loop, and the bound is not arbitrary: every non-empty read
returns at least one byte, so reading a file of the measured length takes at most `size`
iterations. The `+ 1` leaves room for the read that observes EOF, which is what ends the loop in
the ordinary case; the count only stops a file that has outgrown the size it was measured at.
-/
def streamFile (path : System.FilePath) (size : Nat) (chunkSize : UInt64 := 65536) :
    Async Body.Stream :=
  Body.stream fun s => do
    let handle ← IO.FS.Handle.mk path .read
    let rec loop (remaining : Nat) : Async Unit := do
      match remaining with
      | 0 => pure ()
      | n + 1 =>
        let bytes ← handle.read chunkSize.toUSize
        if h : bytes.isEmpty then
          pure ()
        else do
          s.send (Chunk.ofByteArray bytes)
          loop (n + 1 - bytes.size)
    termination_by remaining
    decreasing_by
      simp only [ByteArray.isEmpty, beq_iff_eq] at h
      omega
    loop (size + 1)

/-- A weak ETag derived from a file's modification time and size (no content hash is available
in this toolchain; this is the same fallback most static file servers use). -/
def weakETagOf (md : IO.FS.Metadata) : ETag :=
  let hex (n : Nat) := String.ofList (Nat.toDigits 16 n)
  { value := s!"{hex md.modified.sec.toNat}-{hex md.byteSize.toNat}", weak := true }

def lastModifiedOf (md : IO.FS.Metadata) : LastModified :=
  let timestamp :=
    Std.Time.Timestamp.ofSecondsSinceUnixEpoch (Std.Time.Second.Offset.ofNat md.modified.sec.toNat)
  { date := Std.Time.DateTime.ofTimestampWithZone timestamp Std.Time.TimeZone.UTC }

end Middleware.File

namespace Middleware

/--
Serves static files from `root`. On each request: resolves the path (rejecting traversal
attempts, see `Middleware.File.joinSafeSegments`); if it doesn't resolve, doesn't exist, or is a
directory, falls through to the inner handler (this middleware doesn't own 404 handling).
Otherwise streams the file with `Last-Modified` and a weak `ETag` set
from its metadata.

Deliberately does not set `Content-Type` itself -- compose `contentType` outside it
(`[contentType, notModified, file root]`) to reuse the existing extension-lookup table instead of
duplicating it.
-/
def file (root : System.FilePath) : Middleware :=
  fun handler =>
    { handler with
      onRequest := fun req => do
        match File.resolvePath root req.line.uri.path with
        | none => handler.onRequest req
        | some path =>
          if !(← path.pathExists) then
            handler.onRequest req
          else if (← path.isDir) then
            handler.onRequest req
          else if !(← File.isContainedIn root path) then
            handler.onRequest req
          else do
            let md ← path.metadata
            let etag := File.weakETagOf md
            let lastModified := File.lastModifiedOf md
            let body ← File.streamFile path md.byteSize.toNat
            let headers :=
              Headers.empty
                |>.insert (ETag.serialize etag).fst (ETag.serialize etag).snd
                |>.insert (LastModified.serialize lastModified).fst (LastModified.serialize lastModified).snd
            pure { line := { status := .ok, headers }, body := Body.Any.ofBody body } }

end Middleware
