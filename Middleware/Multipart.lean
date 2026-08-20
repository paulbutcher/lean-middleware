/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import Middleware.Core

public section

open Std.Http
open Std.Http.Server

namespace Middleware.Multipart

/--
Finds every position in `haystack` where `needle` occurs. Scans one byte position at a time
regardless of whether a match was found there, so termination is the same simple "index strictly
increases, bounded by `haystack.size`" argument `Std.Http.URI.isValidPercentEncoding` uses --
deliberately not a "jump to the next match" search, which would need a harder termination proof.
-/
@[expose] def findAllOccurrences (haystack needle : ByteArray) : Array Nat :=
  if needle.isEmpty then
    #[]
  else
    let rec loop (i : Nat) (acc : Array Nat) : Array Nat :=
      if h : i < haystack.size then
        let acc :=
          if i + needle.size ≤ haystack.size ∧ haystack.extract i (i + needle.size) == needle then
            acc.push i
          else
            acc
        loop (i + 1) acc
      else
        acc
    termination_by haystack.size - i
    loop 0 #[]

/-- Splits `"key1=value1; key2=\"value2\""`-style header parameters, unquoting quoted values. -/
def parseParams (s : String) : List (String × String) :=
  (s.splitOn ";").filterMap fun part =>
    match part.splitOn "=" with
    | [] => none
    | [_] => none
    | key :: rest =>
      let key := key.trimAscii.toString.toLower
      let rawValue := (String.intercalate "=" rest).trimAscii.toString
      (Std.Http.Internal.unquoteHttpString? rawValue).map (key, ·)

def paramGet (params : List (String × String)) (key : String) : Option String :=
  (params.find? (·.fst == key)).map Prod.snd

/-- Extracts the `boundary` parameter from a `Content-Type: multipart/form-data; boundary=...`
request, or `none` if the request isn't `multipart/form-data`. -/
def boundaryOf (headers : Headers) : Option String := do
  let v ← headers.get? Header.Name.contentType
  let mediaType := (v.value.splitOn ";").head?.getD "" |>.trimAscii.toString.toLower
  guard (mediaType == "multipart/form-data")
  paramGet (parseParams v.value) "boundary"

def dashBoundaryOf (boundary : String) : ByteArray :=
  ("--" ++ boundary).toUTF8

def delimiterOf (boundary : String) : ByteArray :=
  ("\r\n--" ++ boundary).toUTF8

/--
Splits a multipart body into each part's raw bytes (headers + blank line + content, not yet
parsed). Requires the body to start with the literal dash-boundary (no preamble) -- anything else
is treated as malformed and yields no parts, per the pragmatic-subset scope (real clients never
send a preamble; failing safely here is correct, not a limitation worth working around).
-/
def splitParts (boundary : String) (body : ByteArray) : Array ByteArray :=
  let dashBoundary := dashBoundaryOf boundary
  let delimiter := delimiterOf boundary
  if dashBoundary.size ≤ body.size ∧ body.extract 0 dashBoundary.size == dashBoundary then
    let delimiterPositions := findAllOccurrences body delimiter
    match delimiterPositions.toList with
    | [] => #[]
    | positions =>
      let starts :=
        #[dashBoundary.size + 2] ++ (positions.dropLast.map (· + delimiter.size + 2)).toArray
      (starts.zip delimiterPositions).map fun (s, e) =>
        if s ≤ e then body.extract s e else ByteArray.empty
  else
    #[]

def blankLine : ByteArray := "\r\n\r\n".toUTF8

/-- Splits a part's raw bytes at the blank line into its header block (as text -- headers are
always ASCII) and its content (left as raw bytes, since content may be arbitrary binary). -/
def splitHeadersAndContent (partBytes : ByteArray) : Option (String × ByteArray) := do
  let pos ← (findAllOccurrences partBytes blankLine).toList.head?
  let headerText ← String.fromUTF8? (partBytes.extract 0 pos)
  some (headerText, partBytes.extract (pos + blankLine.size) partBytes.size)

def parseHeaderLines (headerText : String) : List (String × String) :=
  (headerText.splitOn "\r\n").filterMap fun line =>
    match line.splitOn ":" with
    | [] => none
    | [_] => none
    | name :: rest =>
      some (name.trimAscii.toString.toLower, (String.intercalate ":" rest).trimAscii.toString)

/-- Where a part's content ends up: kept in memory, or spooled to a temp file when it exceeds
`MultipartOptions.maxInMemoryPartSize`. -/
inductive PartContent where
  | bytes (data : ByteArray)
  | tempFile (path : System.FilePath) (size : Nat)

structure Part where
  name : String
  filename : Option String
  contentType : Option String
  content : PartContent

def routeStorage (content : ByteArray) (maxInMemorySize : Nat) : IO PartContent := do
  if content.size ≤ maxInMemorySize then
    pure (.bytes content)
  else
    let (handle, path) ← IO.FS.createTempFile
    handle.write content
    handle.flush
    pure (.tempFile path content.size)

def buildPart (headerLines : List (String × String)) (content : ByteArray) (maxInMemorySize : Nat) :
    IO (Option Part) := do
  match headerLines.find? (·.fst == "content-disposition") with
  | none => pure none
  | some (_, disposition) =>
    let dispType := (disposition.splitOn ";").head?.getD "" |>.trimAscii.toString.toLower
    if dispType != "form-data" then
      pure none
    else
      match paramGet (parseParams disposition) "name" with
      | none => pure none
      | some name =>
        let filename := paramGet (parseParams disposition) "filename"
        let contentType := (headerLines.find? (·.fst == "content-type")).map Prod.snd
        let partContent ← routeStorage content maxInMemorySize
        pure (some { name, filename, contentType, content := partContent })

end Middleware.Multipart

namespace Middleware

/-- Options controlling `multipartParams`'s parsing limits and storage threshold. -/
structure MultipartOptions where
  /-- Requests with more parts than this are rejected with `413`. -/
  maxPartCount : Nat := 100
  /--
  Any single part larger than this is rejected with `413`, checked against the part's raw bytes
  (its header block included, not just its content) before parsing -- deliberately cheap to check
  first, so an oversized part is rejected before any header-parsing or storage-routing work.
  -/
  maxPartSize : Nat := 10 * 1024 * 1024
  /-- Parts at or under this size are kept in memory; larger parts spool to a temp file. -/
  maxInMemoryPartSize : Nat := 1024 * 1024

/-- The parsed parts of a `multipart/form-data` request. -/
structure MultipartParams where
  parts : List Multipart.Part
deriving TypeName

namespace MultipartParams

/-- The first part with the given field `name`, if any. -/
def get (p : MultipartParams) (name : String) : Option Multipart.Part :=
  p.parts.find? (·.name == name)

end MultipartParams

private inductive ParseOutcome where
  | ok (parts : List Multipart.Part)
  | tooLarge

private def parseMultipart (boundary : String) (body : ByteArray) (options : MultipartOptions) :
    IO ParseOutcome := do
  let rawParts := Multipart.splitParts boundary body
  if rawParts.size > options.maxPartCount ∨ rawParts.any (·.size > options.maxPartSize) then
    pure .tooLarge
  else do
    let mut parts : List Multipart.Part := []
    for raw in rawParts do
      match Multipart.splitHeadersAndContent raw with
      | none => pure ()
      | some (headerText, content) =>
        match ← Multipart.buildPart (Multipart.parseHeaderLines headerText) content
            options.maxInMemoryPartSize with
        | none => pure ()
        | some part => parts := parts ++ [part]
    pure (.ok parts)

private def removeTempFiles (parts : List Multipart.Part) : IO Unit :=
  parts.forM fun p => match p.content with
    | .tempFile path _ => try IO.FS.removeFile path catch _ => pure ()
    | .bytes _ => pure ()

/--
Attaches a `MultipartParams` extension to the request when it's `multipart/form-data`, otherwise
passes the request through unchanged. Parts over `MultipartOptions.maxPartSize`, or more parts
than `maxPartCount`, short-circuit to `413 Payload Too Large` without calling the inner handler
(the same short-circuiting shape `catchAll` uses for `500`).

Temp-file-backed parts (see `MultipartOptions.maxInMemoryPartSize`) are removed once the wrapped
handler returns -- persist anything you need (read it, move it, stream it onward) during the
request, not afterward.

Unlike `params`, this does not restore a re-readable body afterward: nothing downstream re-parses
a multipart body, and reconstructing one from temp-file-spooled parts wouldn't be useful.
-/
def multipartParams (options : MultipartOptions := {}) : Middleware :=
  fun handler =>
    { handler with
      onRequest := fun req => do
        match Multipart.boundaryOf req.line.headers with
        | none => handler.onRequest req
        | some boundary =>
          let bodyBytes ← req.body.readAll (α := ByteArray)
          match ← parseMultipart boundary bodyBytes options with
          | .tooLarge => Response.withStatus Status.payloadTooLarge |>.text "Payload Too Large"
          | .ok parts =>
            let req := { req with extensions := req.extensions.insert (MultipartParams.mk parts) }
            try
              handler.onRequest req
            finally
              removeTempFiles parts }

end Middleware
