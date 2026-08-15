/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Middleware
import Std.Http.Test.Helpers

open Std.Http
open Std.Http.Server
open Std.Http.Internal.Test
open Middleware (catchAll cookies session flash params contentType notModified file
  multipartParams MemoryStore SessionStore SessionData SessionUpdate Params MultipartParams
  forwardedScheme sslRedirect hsts xFrameOptions HstsOptions SslRedirectOptions
  antiForgery AntiForgeryToken)

namespace Tests.Integration

/-- Extracts a response header's raw value, if present. -/
def extractHeaderValue (response : ByteArray) (name : String) : Option String :=
  let text := String.fromUTF8! response
  let prefix_ := s!"{name}: "
  match (text.splitOn "\x0d\n").find? (·.startsWith prefix_) with
  | none => none
  | some line => some (line.drop prefix_.length).toString

/-- Extracts a cookie's raw wire value from a `Set-Cookie:` response line, if present. -/
def extractCookieValue (response : ByteArray) (name : String) : Option String :=
  let text := String.fromUTF8! response
  let prefix_ := s!"Set-Cookie: {name}="
  match (text.splitOn "\x0d\n").find? (·.startsWith prefix_) with
  | none => none
  | some line => some ((line.drop prefix_.length).toString.splitOn ";" |>.headD "")

/-- The recommended default order from `Middleware.apply`'s doc comment, minus `file` (each test
supplies its own base handler). -/
def stackAround (store : MemoryStore) (handler : StatelessHandler) : StatelessHandler :=
  Middleware.apply
    [catchAll (fun _ => pure ()), cookies, session store {}, flash, params,
     contentType "application/octet-stream", notModified] handler

def paramsAndSessionHandler : StatelessHandler :=
  { onRequest := fun req => do
      let name := ((req.extensions.get Params).bind (Params.get · "name")).getD "<no-name>"
      Response.ok |>.extension (SessionUpdate.write [("visited", "yes")]) |>.text s!"name={name}" }

def readVisitedHandler : StatelessHandler :=
  { onRequest := fun req => do
      let data := (req.extensions.get SessionData).getD {} |>.data
      Response.ok |>.text (data.get "visited" |>.getD "<missing>") }

def throwingHandler : StatelessHandler :=
  { onRequest := fun _ => throw (IO.Error.userError "integration boom") }

/-- A query param, a form param won't apply here since it's a GET, but the query param and a
session write both work in the same pass through the full stack, and the session persists to a
second request. -/
def fullStackParamsAndSessionTest : IO Unit := do
  let store ← MemoryStore.new
  let capturedCookie ← IO.mkRef (none : Option String)
  check "a query param and a session write both work in one request through the full stack"
    (mkGetClose "/greet?name=world") (stackAround store paramsAndSessionHandler).onRequest
    fun response => do
      assertContains response "name=world"
      capturedCookie.set (extractCookieValue response "lean-session")
  match ← capturedCookie.get with
  | none => throw <| IO.userError "expected a Set-Cookie to be issued"
  | some sid =>
    check "the session written in the first request is readable in the second"
      (mkGet "/" s!"Cookie: lean-session={sid}\x0d\nConnection: close\x0d\n")
      (stackAround store readVisitedHandler).onRequest fun response =>
        assertContains response "yes"

/-- `catchAll`'s `try/catch` intercepts a thrown error before it ever unwinds back through
`session`/`cookies`'s own response-side logic, so an established session is left completely
untouched (no re-issued or modified `Set-Cookie`) when a later request on the same stack errors
out -- not just "no session was ever written", but "an existing one is provably left alone". -/
def catchAllShieldsSessionOnErrorTest : IO Unit := do
  let store ← MemoryStore.new
  let capturedCookie ← IO.mkRef (none : Option String)
  check "establishing a session" (mkGetClose "/greet?name=world")
    (stackAround store paramsAndSessionHandler).onRequest fun response =>
      capturedCookie.set (extractCookieValue response "lean-session")
  match ← capturedCookie.get with
  | none => throw <| IO.userError "expected a Set-Cookie to be issued"
  | some sid =>
    check "a later request that throws becomes 500 without touching the established session"
      (mkGet "/" s!"Cookie: lean-session={sid}\x0d\nConnection: close\x0d\n")
      (stackAround store throwingHandler).onRequest fun response => do
        assertStatus response "HTTP/1.1 500"
        assertAbsent response "Set-Cookie"

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

/-- `contentType` and `notModified` composed around a real `file` middleware, serving a real
fixture: the first request's real `ETag` (not a hand-built fake one, unlike
`Tests/NotModified.lean`'s isolated test) is presented back as `If-None-Match` and produces a
real `304`. -/
def realFileConditionalGetIntegrationTest : IO Unit :=
  withFixtureDir fun dir => do
    let stack := Middleware.apply
      [catchAll (fun _ => pure ()), contentType "application/octet-stream", notModified]
      (file dir notFoundHandler)
    let capturedETag ← IO.mkRef (none : Option String)
    check "GET on a real file returns 200 with a real ETag" (mkGetClose "/hello.txt")
      stack.onRequest fun response => do
        assertStatus response "HTTP/1.1 200"
        assertContains response "hello world"
        capturedETag.set (extractHeaderValue response "Etag")
    match ← capturedETag.get with
    | none => throw <| IO.userError "expected an Etag to be issued"
    | some etag =>
      check "presenting that ETag back as If-None-Match becomes a real 304"
        (mkGet "/hello.txt" s!"If-None-Match: {etag}\x0d\nConnection: close\x0d\n")
        stack.onRequest fun response => do
          assertStatus response "HTTP/1.1 304"
          assertAbsent response "hello world"

def multipartBoundary : String := "----integrationBoundary"

def multipartContentTypeHeader : String :=
  s!"Content-Type: multipart/form-data; boundary={multipartBoundary}\x0d\n"

def multipartBody : String :=
  s!"--{multipartBoundary}\x0d\nContent-Disposition: form-data; name=\"title\"\x0d\n\x0d\n\
    hello\x0d\n--{multipartBoundary}--\x0d\n"

def multipartAndSessionHandler : StatelessHandler :=
  { onRequest := fun req => do
      let title :=
        match (req.extensions.get MultipartParams).getD { parts := [] } |>.get "title" with
        | some part => match part.content with
          | .bytes data => String.fromUTF8! data
          | .tempFile _ _ => "<file>"
        | none => "<missing>"
      let visited := (req.extensions.get SessionData).getD {} |>.data.get "visited" |>.getD "<missing>"
      Response.ok |>.text s!"title={title};visited={visited}" }

/-- A multipart body and a session cookie both resolve correctly in the same request -- draining
the body for multipart parsing doesn't interfere with cookie/session extraction, which reads only
the `Cookie` header, not the body. -/
def multipartWithSessionTest : IO Unit := do
  let store ← MemoryStore.new
  let sid ← SessionStore.write store none [("visited", "yes")]
  let stack := Middleware.apply [cookies, session store {}, multipartParams {}]
    multipartAndSessionHandler
  check "a multipart body and a session cookie both resolve in one request"
    (mkPost "/" multipartBody
      (multipartContentTypeHeader ++ s!"Cookie: lean-session={sid}\x0d\nConnection: close\x0d\n"))
    stack.onRequest fun response => do
      assertContains response "title=hello"
      assertContains response "visited=yes"

/-- An `http` request behind a simulated reverse proxy is redirected to `https` before any inner
middleware runs at all -- proven by wrapping a handler that throws if it's ever reached. -/
def sslRedirectShortCircuitsBeforeInnerStackTest : IO Unit :=
  check "an http request is redirected before reaching a handler that would throw"
    (mkGetClose "/secure")
    (Middleware.apply
      [forwardedScheme Middleware.Header.Name.xForwardedProto, sslRedirect ({} : SslRedirectOptions)]
      throwingHandler).onRequest fun response => do
      assertStatus response "HTTP/1.1 301"
      assertContains response "Location: https://example.com/secure"

/-- The security-header middlewares sit outside `catchAll` in the recommended order specifically
so a `500` still carries them -- confirmed against the real `catchAll` short-circuit, not just
each middleware in isolation. -/
def securityHeadersSurviveCatchAllTest : IO Unit :=
  check "hsts and X-Frame-Options still apply to a 500 produced by catchAll" (mkGetClose "/")
    (Middleware.apply [hsts ({} : HstsOptions), xFrameOptions .sameOrigin, catchAll (fun _ => pure ())]
      throwingHandler).onRequest fun response => do
      assertStatus response "HTTP/1.1 500"
      assertContains response "Strict-Transport-Security"
      assertContains response "X-Frame-Options: SAMEORIGIN"

def echoAntiForgeryTokenHandler : StatelessHandler :=
  { onRequest := fun req => do
      let token := (req.extensions.get AntiForgeryToken).map (·.value) |>.getD "<missing>"
      Response.ok |>.text token }

def reachedInnerHandler : StatelessHandler :=
  { onRequest := fun _ => Response.ok |>.text "reached-inner" }

/-- `cookies, session, params, antiForgery` composed end to end: a GET establishes a session and
its token (read back via the `AntiForgeryToken` extension), a follow-up POST without it is
rejected, and a POST echoing that token as a form field reaches the inner handler. -/
def antiForgeryFullStackTest : IO Unit := do
  let store ← MemoryStore.new
  let stack := Middleware.apply [cookies, session store {}, params, antiForgery {}]
  let cookieRef ← IO.mkRef (none : Option String)
  let tokenRef ← IO.mkRef (none : Option String)
  check "a GET establishes a session and its anti-forgery token" (mkGetClose "/")
    (stack echoAntiForgeryTokenHandler).onRequest fun response => do
      cookieRef.set (extractCookieValue response "lean-session")
      tokenRef.set (some (String.fromUTF8! response |>.splitOn "\x0d\n\x0d\n" |>.getD 1 ""))
  match ← cookieRef.get, ← tokenRef.get with
  | none, _ => throw <| IO.userError "expected a Set-Cookie to be issued"
  | _, none => throw <| IO.userError "expected a token body to be captured"
  | some sid, some token =>
    check "a POST without the token is rejected before reaching the inner handler"
      (mkPost "/" "" s!"Cookie: lean-session={sid}\x0d\nConnection: close\x0d\n")
      (stack paramsAndSessionHandler).onRequest fun response => assertStatus response "HTTP/1.1 403"
    check "a POST echoing that token as a form field reaches the inner handler"
      (mkPost "/" s!"__anti-forgery-token={token}"
        s!"Content-Type: application/x-www-form-urlencoded\x0d\nCookie: lean-session={sid}\x0d\nConnection: close\x0d\n")
      (stack reachedInnerHandler).onRequest fun response => assertContains response "reached-inner"

def run : IO Unit :=
  runGroup "Integration" do
    fullStackParamsAndSessionTest
    catchAllShieldsSessionOnErrorTest
    realFileConditionalGetIntegrationTest
    multipartWithSessionTest
    sslRedirectShortCircuitsBeforeInnerStackTest
    securityHeadersSurviveCatchAllTest
    antiForgeryFullStackTest

end Tests.Integration
