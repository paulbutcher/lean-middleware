/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Middleware.Multipart
import Std.Http.Test.Helpers
import Plausible

open Std.Http
open Std.Http.Server
open Std.Http.Internal.Test
open Middleware (multipartParams MultipartOptions MultipartParams)

namespace Tests.Multipart

def boundary : String := "----testBoundary123"

def contentTypeHeader : String :=
  s!"Content-Type: multipart/form-data; boundary={boundary}\x0d\nConnection: close\x0d\n"

def formField (name value : String) : String :=
  s!"--{boundary}\x0d\nContent-Disposition: form-data; name=\"{name}\"\x0d\n\x0d\n{value}\x0d\n"

def fileField (name filename contentType content : String) : String :=
  s!"--{boundary}\x0d\nContent-Disposition: form-data; name=\"{name}\"; filename=\"{filename}\"\x0d\n\
    Content-Type: {contentType}\x0d\n\x0d\n{content}\x0d\n"

def closeBoundary : String := s!"--{boundary}--\x0d\n"

def echoPartsHandler : StatelessHandler :=
  { onRequest := fun req => do
      let mp := (req.extensions.get MultipartParams).getD { parts := [] }
      let summary := mp.parts.foldl (init := "") fun acc p =>
        let kind := match p.content with
          | .bytes data => s!"bytes:{data.size}"
          | .tempFile _ size => s!"tempFile:{size}"
        acc ++ s!"{p.name}={kind};"
      Response.ok |>.text summary }

def parsesFieldsAndFilesTest : IO Unit :=
  let body := formField "title" "hello world" ++
    fileField "upload" "a.txt" "text/plain" "file contents" ++ closeBoundary
  let stack := multipartParams {} echoPartsHandler
  check "extracts a form field and a file field" (mkPost "/" body contentTypeHeader)
    stack.onRequest fun response => do
      assertContains response "title=bytes:11"
      assertContains response "upload=bytes:13"

def nonMultipartPassesThroughTest : IO Unit :=
  let passthroughHandler : StatelessHandler := { onRequest := fun _ => Response.ok |>.text "passthrough" }
  let stack := multipartParams {} passthroughHandler
  check "non-multipart request passes through unchanged" (mkGetClose "/")
    stack.onRequest fun response => do
      assertStatus response "HTTP/1.1 200"
      assertContains response "passthrough"

def malformedBodyRejectedSafelyTest : IO Unit :=
  let stack := multipartParams {} echoPartsHandler
  check "a body not starting with the boundary yields no parts rather than crashing"
    (mkPost "/" "not a multipart body at all" contentTypeHeader) stack.onRequest fun response =>
      assertStatus response "HTTP/1.1 200"

def tooManyPartsRejectedTest : IO Unit :=
  let body := formField "a" "1" ++ formField "b" "2" ++ closeBoundary
  let stack := multipartParams { maxPartCount := 1 } echoPartsHandler
  check "more parts than maxPartCount becomes 413" (mkPost "/" body contentTypeHeader)
    stack.onRequest fun response => assertStatus response "HTTP/1.1 413"

def partTooLargeRejectedTest : IO Unit :=
  let body := formField "a" "this value is definitely longer than five bytes" ++ closeBoundary
  let stack := multipartParams { maxPartSize := 5 } echoPartsHandler
  check "a part larger than maxPartSize becomes 413" (mkPost "/" body contentTypeHeader)
    stack.onRequest fun response => assertStatus response "HTTP/1.1 413"

def sizeThresholdRoutingTest : IO Unit := do
  let capturedPath ← IO.mkRef (none : Option System.FilePath)
  let bigContent := String.ofList (List.replicate 2000 'x')
  let handler : StatelessHandler :=
    { onRequest := fun req => do
        let mp := (req.extensions.get MultipartParams).getD { parts := [] }
        match mp.get "big" with
        | some part =>
          match part.content with
          | .tempFile path size => do
            capturedPath.set (some path)
            let onDisk ← IO.FS.readBinFile path
            Response.ok |>.text s!"tempFile:{onDisk.size == size}"
          | .bytes _ => Response.ok |>.text "unexpectedly in memory"
        | none => Response.ok |>.text "missing" }
  let body := formField "small" "tiny" ++
    fileField "big" "big.bin" "application/octet-stream" bigContent ++ closeBoundary
  let stack := multipartParams { maxInMemoryPartSize := 100 } handler
  check "a part over maxInMemoryPartSize spools to a temp file with correct content"
    (mkPost "/" body contentTypeHeader) stack.onRequest fun response =>
      assertContains response "tempFile:true"
  match ← capturedPath.get with
  | none => throw <| IO.userError "expected a captured temp file path"
  | some path =>
    if ← path.pathExists then
      throw <| IO.userError s!"expected temp file {path} to be removed after the handler returns"

def occurrenceHolds (prefixLen suffixLen : Nat) : Bool :=
  let needle := "NEEDLE".toUTF8
  let pre := (String.ofList (List.replicate (prefixLen % 50) 'a')).toUTF8
  let suffix := (String.ofList (List.replicate (suffixLen % 50) 'b')).toUTF8
  (Middleware.Multipart.findAllOccurrences (pre ++ needle ++ suffix) needle).contains pre.size

def occurrenceFoundTest : IO Unit := do
  match ← Plausible.Testable.checkIO
      (Plausible.NamedBinder "prefixLen" <| ∀ prefixLen : Nat,
       Plausible.NamedBinder "suffixLen" <| ∀ suffixLen : Nat,
       occurrenceHolds prefixLen suffixLen = true) with
  | .success _ => pure ()
  | .gaveUp n => throw <| IO.userError s!"gave up after {n} tries"
  | .failure _ steps _ => throw <| IO.userError s!"counter-example found: {steps}"

def noOccurrenceHolds (len : Nat) : Bool :=
  let needle := "NEEDLE".toUTF8
  let haystack := (String.ofList (List.replicate (len % 50) 'z')).toUTF8
  (Middleware.Multipart.findAllOccurrences haystack needle).isEmpty

def noOccurrenceTest : IO Unit := do
  match ← Plausible.Testable.checkIO
      (Plausible.NamedBinder "len" <| ∀ len : Nat, noOccurrenceHolds len = true) with
  | .success _ => pure ()
  | .gaveUp n => throw <| IO.userError s!"gave up after {n} tries"
  | .failure _ steps _ => throw <| IO.userError s!"counter-example found: {steps}"

def run : IO Unit :=
  runGroup "Middleware.Multipart" do
    parsesFieldsAndFilesTest
    nonMultipartPassesThroughTest
    malformedBodyRejectedSafelyTest
    tooManyPartsRejectedTest
    partTooLargeRejectedTest
    sizeThresholdRoutingTest
    occurrenceFoundTest
    noOccurrenceTest

end Tests.Multipart
