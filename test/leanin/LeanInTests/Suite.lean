/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Middleware
import LeanInTests.Harness

namespace LeanInTests

open Routing
open Std.Http
open Middleware (params Params multipartParams MultipartParams catchAll cookies session MemoryStore
  SessionData SessionUpdate antiForgery AntiForgeryToken file)

def answer (builder : Response.Builder) (s : String) :
    LeanIn.Runtime.VM (Response LeanIn.Http.ResponseBody) :=
  Engine.leanin.text builder s

def notFound : StatelessHandler .leanin :=
  { onRequest := fun _ => answer Response.notFound "not found" }

def formHeaders : List (String × String) :=
  [("Content-Type", "application/x-www-form-urlencoded")]

/-- Several of LeanIn's reads long, so that a limit has to hold across reads. -/
def largeForm : ByteArray :=
  ("a=" ++ String.ofList (List.replicate 100000 'x')).toUTF8

def lengthHandler : StatelessHandler .leanin :=
  { onRequest := fun req =>
      answer Response.ok s!"length {(((req.extensions.get Params).bind (·.get "a")).getD "").length}" }

def bodyHandler : StatelessHandler .leanin :=
  { onRequest := fun req => do
      match ← ServerEngine.readText req.body 1024 with
      | .text body => answer Response.ok body
      | _ => answer Response.badRequest "unreadable" }

def paramsTest : IO Unit := do
  let o ← run (params { maxBodySize := largeForm.size } lengthHandler) .post "/" formHeaders largeForm
  check s!"params: a form body exactly at the limit should be read whole, got {o.text}"
    (o.text == "length 100000")
  let o ← run (params { maxBodySize := largeForm.size - 1 } lengthHandler) .post "/" formHeaders
    largeForm
  check s!"params: a form body a byte over the limit should be 413, got {repr o.status}"
    (o.status == .payloadTooLarge)
  let o ← run (params {} lengthHandler) .post "/" formHeaders (ByteArray.mk #[0x61, 0x3d, 0xff])
  check s!"params: a form body that is not UTF-8 should be 400, got {repr o.status}"
    (o.status == .badRequest)
  let o ← run (params {} bodyHandler) .post "/" formHeaders "a=b".toUTF8
  check s!"params: the handler should still be able to read the body, got {o.text}"
    (o.text == "a=b")

def boundary : String := "----testBoundary123"

def largeMultipart : ByteArray :=
  (s!"--{boundary}\x0d\nContent-Disposition: form-data; name=\"big\"; filename=\"big.bin\"\x0d\n\
    \x0d\n{String.ofList (List.replicate 100000 'x')}\x0d\n--{boundary}--\x0d\n").toUTF8

def multipartHeaders : List (String × String) :=
  [("Content-Type", s!"multipart/form-data; boundary={boundary}")]

def partsHandler : StatelessHandler .leanin :=
  { onRequest := fun req =>
      let parts := ((req.extensions.get MultipartParams).map (·.parts)).getD []
      answer Response.ok (String.intercalate ";" (parts.map fun p =>
        match p.content with
        | .bytes data => s!"{p.name}=bytes:{data.size}"
        | .tempFile _ size => s!"{p.name}=tempFile:{size}")) }

def multipartTest : IO Unit := do
  let o ← run (multipartParams { maxBodySize := largeMultipart.size } partsHandler) .post "/"
    multipartHeaders largeMultipart
  check s!"multipartParams: a body exactly at the limit should be parsed, got {o.text}"
    (o.text == "big=bytes:100000")
  let o ← run (multipartParams { maxBodySize := largeMultipart.size - 1 } partsHandler) .post "/"
    multipartHeaders largeMultipart
  check s!"multipartParams: a body a byte over the limit should be 413, got {repr o.status}"
    (o.status == .payloadTooLarge)

def catchAllTest : IO Unit := do
  let reported ← IO.mkRef (none : Option String)
  let throwing : StatelessHandler .leanin :=
    { onRequest := fun _ => throw (IO.userError "boom")
      onFailure := fun err => (reported.set (some (toString err)) : IO Unit) }
  let o ← run (catchAll throwing) .get "/"
  check s!"catchAll: a thrown error should become a 500, got {repr o.status}"
    (o.status == .internalServerError && o.text == "Internal Server Error")
  check s!"catchAll: the error should reach onFailure, got {repr (← reported.get)}"
    ((← reported.get) == some "boom")

/-- The `name=value` pair of the first `Set-Cookie`, as a browser would send it back. -/
def cookiePair? (o : Outcome) : Option String :=
  (o.headers? "set-cookie").head?.bind fun c => (c.splitOn ";").head?

def sessionTest : IO Unit := do
  let store ← MemoryStore.new
  let handler : StatelessHandler .leanin :=
    { onRequest := fun req =>
        if req.line.uri.path.toDecodedSegments == #["set"] then
          answer (Response.ok.extension (SessionUpdate.write [("user", "ada")])) "set"
        else
          let user := ((req.extensions.get SessionData).bind (Middleware.Session.get ·.data "user")).getD "-"
          answer Response.ok s!"user {user}" }
  let stack := cookies (session store {} handler)
  let some cookie := cookiePair? (← run stack .get "/set")
    | throw (IO.userError "session: writing a session should set its cookie")
  let o ← run stack .get "/get" [("Cookie", cookie)]
  check s!"session: the session should be read back on the next request, got {o.text}"
    (o.text == "user ada")

def antiForgeryTest : IO Unit := do
  let store ← MemoryStore.new
  let handler : StatelessHandler .leanin :=
    { onRequest := fun req =>
        answer Response.ok s!"token {((req.extensions.get AntiForgeryToken).map (·.value)).getD ""}" }
  let stack := cookies (session store {} (params {} (antiForgery {} handler)))
  let page ← run stack .get "/"
  let some cookie := cookiePair? page
    | throw (IO.userError "antiForgery: the first page should set a session cookie")
  let token := (page.text.drop "token ".length).toString
  let refused ← run stack .post "/" (("Cookie", cookie) :: formHeaders) .empty
  check s!"antiForgery: a post without a token should be 403, got {repr refused.status}"
    (refused.status == .forbidden)
  let accepted ← run stack .post "/" (("Cookie", cookie) :: formHeaders)
    s!"{Middleware.defaultAntiForgeryParamName}={token}".toUTF8
  check s!"antiForgery: a post carrying the token should pass, got {repr accepted.status}"
    (accepted.status == .ok && accepted.text == s!"token {token}")

def fileTest : IO Unit := do
  let dir ← IO.FS.createTempDir
  try
    let contents := String.ofList (List.replicate 200000 'y')
    IO.FS.writeFile (dir / "big.txt") contents
    let o ← run (file dir notFound) .get "/big.txt"
    check s!"file: a file larger than a chunk should stream whole, got {o.body.size} bytes"
      (o.status == .ok && o.body == contents.toUTF8)
  finally
    IO.FS.removeDirAll dir

def all : IO Unit := do
  paramsTest
  multipartTest
  catchAllTest
  sessionTest
  antiForgeryTest
  fileTest

end LeanInTests
