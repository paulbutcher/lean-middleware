/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Middleware.Multipart
import Std.Http.Test.Helpers

open Std.Http
open Std.Http.Server
open Std.Http.Internal.Test
open Middleware (multipartParams MultipartOptions MultipartParams)
open Middleware.Multipart (findAllOccurrences)

namespace Tests.Multipart

private theorem loop_sound (haystack needle : ByteArray) (i : Nat) (acc : Array Nat) :
    (∀ j ∈ acc, j + needle.size ≤ haystack.size ∧
        (haystack.extract j (j + needle.size) == needle) = true) →
    ∀ j ∈ findAllOccurrences.loop haystack needle i acc,
      j + needle.size ≤ haystack.size ∧
        (haystack.extract j (j + needle.size) == needle) = true := by
  fun_induction findAllOccurrences.loop haystack needle i acc with
  | case1 i acc h acc' ih =>
    intro hacc
    refine ih fun j hj => ?_
    simp only [acc'] at hj
    split at hj
    · rename_i hmatch
      rcases Array.mem_push.mp hj with hj | rfl
      · exact hacc j hj
      · exact hmatch
    · exact hacc j hj
  | case2 i acc h => intro hacc; exact hacc

private theorem loop_mem_of_mem (haystack needle : ByteArray) (i : Nat) (acc : Array Nat)
    (x : Nat) : x ∈ acc → x ∈ findAllOccurrences.loop haystack needle i acc := by
  fun_induction findAllOccurrences.loop haystack needle i acc with
  | case1 i acc h acc' ih =>
    intro hx
    refine ih ?_
    simp only [acc']
    split
    · exact Array.mem_push.mpr (Or.inl hx)
    · exact hx
  | case2 i acc h => intro hx; exact hx

private theorem loop_complete (haystack needle : ByteArray) (i : Nat) (acc : Array Nat) (j : Nat)
    (hij : i ≤ j) (hjs : j < haystack.size)
    (hmatch : j + needle.size ≤ haystack.size ∧
      (haystack.extract j (j + needle.size) == needle) = true) :
    j ∈ findAllOccurrences.loop haystack needle i acc := by
  fun_induction findAllOccurrences.loop haystack needle i acc with
  | case1 i acc h acc' ih =>
    rcases Nat.eq_or_lt_of_le hij with rfl | hlt
    · refine loop_mem_of_mem _ _ _ _ _ ?_
      simp only [acc']
      rw [dif_pos hmatch]
      exact Array.mem_push.mpr (Or.inr rfl)
    · exact ih hlt
  | case2 i acc h => exact absurd (Nat.lt_of_le_of_lt hij hjs) h

/--
`findAllOccurrences` reports exactly the in-bounds positions where `needle` really occurs:
nothing spurious (which would make `splitParts` cut a part at a position that isn't a delimiter,
splicing one part's content into another's) and nothing missed (which would silently merge two
parts into one).
-/
theorem findAllOccurrences_mem_iff (haystack needle : ByteArray) (i : Nat) :
    i ∈ findAllOccurrences haystack needle ↔
      needle.isEmpty = false ∧ i + needle.size ≤ haystack.size ∧
        (haystack.extract i (i + needle.size) == needle) = true := by
  unfold findAllOccurrences
  split
  · rename_i hemp
    simp [hemp]
  · rename_i hemp
    have hne : needle.isEmpty = false := by simpa using hemp
    have hpos : 0 < needle.size := by
      simp only [ByteArray.isEmpty, beq_eq_false_iff_ne, ne_eq] at hne
      omega
    refine ⟨fun h => ⟨hne, loop_sound haystack needle 0 #[] (by simp) i h⟩, ?_⟩
    rintro ⟨-, hb, hm⟩
    exact loop_complete haystack needle 0 #[] i (Nat.zero_le _) (by omega) ⟨hb, hm⟩

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

def run : IO Unit :=
  runGroup "Middleware.Multipart" do
    parsesFieldsAndFilesTest
    nonMultipartPassesThroughTest
    malformedBodyRejectedSafelyTest
    tooManyPartsRejectedTest
    partTooLargeRejectedTest
    sizeThresholdRoutingTest

end Tests.Multipart
