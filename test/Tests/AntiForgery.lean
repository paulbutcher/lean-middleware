/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import Middleware.AntiForgery
public import Std.Http.Test.Helpers

public section

open Std.Http
open Std.Http.Server
open Std.Http.Internal.Test
open Middleware (cookies session params MemoryStore antiForgery AntiForgeryToken
  AntiForgeryOptions)

namespace Tests.AntiForgery

/-- Extracts a cookie's raw wire value from a `Set-Cookie:` response line, if present. -/
def extractCookieValue (response : ByteArray) (name : String) : Option String :=
  let text := String.fromUTF8! response
  let prefix_ := s!"Set-Cookie: {name}="
  match (text.splitOn "\x0d\n").find? (·.startsWith prefix_) with
  | none => none
  | some line => some ((line.drop prefix_.length).toString.splitOn ";" |>.headD "")

/-- A raw request with an arbitrary method, mirroring `mkGet`'s shape for methods
`Std.Http.Test.Helpers` doesn't provide a dedicated builder for. -/
def mkRequest (method path : String) (extra : String := "") : String :=
  s!"{method} {path} HTTP/1.1\x0d\nHost: example.com\x0d\n{extra}\x0d\n"

def bareHandler : StatelessHandler :=
  { onRequest := fun _ => Response.ok |>.text "reached-inner" }

def echoTokenHandler : StatelessHandler :=
  { onRequest := fun req => do
      let token := (req.extensions.get AntiForgeryToken).map (·.value) |>.getD "<missing>"
      Response.ok |>.text token }

def jsonErrorHandler : StatelessHandler :=
  { onRequest := fun _ => Response.forbidden.json "{\"error\":\"forbidden\"}" }

def safeMethodsPassWithoutSessionTest : IO Unit := do
  for method in ["GET", "OPTIONS"] do
    check s!"a {method} request passes through with no session and no token at all"
      (mkRequest method "/" "Connection: close\x0d\n") (antiForgery {} bareHandler).onRequest
      fun response => assertContains response "reached-inner"
  -- HEAD's response body is stripped by the server per HTTP semantics, so it can only be
  -- confirmed via status, not body content.
  check "a HEAD request passes through with no session and no token at all"
    (mkRequest "HEAD" "/" "Connection: close\x0d\n") (antiForgery {} bareHandler).onRequest
    fun response => assertStatus response "HTTP/1.1 200"

def postWithoutSessionMiddlewareRejectedTest : IO Unit :=
  check "a POST is rejected 403 when `session` isn't wrapped outer at all (fails closed)"
    (mkPost "/" "" "Connection: close\x0d\n") (antiForgery {} bareHandler).onRequest
    fun response => do
      assertStatus response "HTTP/1.1 403"
      assertContains response "Invalid anti-forgery token"

def postNoStoredTokenRejectedTest : IO Unit := do
  let store ← MemoryStore.new
  check "a POST is rejected 403 when a session exists but never had a token established"
    (mkPost "/" "" "Connection: close\x0d\n")
    (cookies (session store {} (antiForgery {} bareHandler))).onRequest fun response =>
      assertStatus response "HTTP/1.1 403"

/-- Runs a GET through `cookies (session store {} (antiForgery {} echoTokenHandler))` to
establish a session and its token, returning the session cookie and the token's own value. -/
def establishToken (store : MemoryStore) : IO (String × String) := do
  let cookieRef ← IO.mkRef (none : Option String)
  let tokenRef ← IO.mkRef (none : Option String)
  check "establishing a session and its anti-forgery token via a safe GET" (mkGetClose "/")
    (cookies (session store {} (antiForgery {} echoTokenHandler))).onRequest fun response => do
      cookieRef.set (extractCookieValue response "lean-session")
      tokenRef.set (some (String.fromUTF8! response |>.splitOn "\x0d\n\x0d\n" |>.getD 1 ""))
  match ← cookieRef.get, ← tokenRef.get with
  | some sid, some token => pure (sid, token)
  | _, _ => throw <| IO.userError "expected a session cookie and a token body to be established"

def postWithMatchingFormTokenSucceedsTest : IO Unit := do
  let store ← MemoryStore.new
  let (sid, token) ← establishToken store
  check "a POST with the token in a form field succeeds through to the inner handler"
    (mkPost "/" s!"__anti-forgery-token={token}"
      s!"Content-Type: application/x-www-form-urlencoded\x0d\nCookie: lean-session={sid}\x0d\nConnection: close\x0d\n")
    (cookies (session store {} (params (antiForgery {} bareHandler)))).onRequest fun response =>
      assertContains response "reached-inner"

def postWithCsrfHeaderTokenSucceedsTest : IO Unit := do
  let store ← MemoryStore.new
  let (sid, token) ← establishToken store
  check "a POST with the token in X-CSRF-Token succeeds through to the inner handler"
    (mkPost "/" ""
      s!"X-CSRF-Token: {token}\x0d\nCookie: lean-session={sid}\x0d\nConnection: close\x0d\n")
    (cookies (session store {} (antiForgery {} bareHandler))).onRequest fun response =>
      assertContains response "reached-inner"

def postWithXsrfHeaderTokenSucceedsTest : IO Unit := do
  let store ← MemoryStore.new
  let (sid, token) ← establishToken store
  check "a POST with the token in X-XSRF-Token succeeds through to the inner handler"
    (mkPost "/" ""
      s!"X-XSRF-Token: {token}\x0d\nCookie: lean-session={sid}\x0d\nConnection: close\x0d\n")
    (cookies (session store {} (antiForgery {} bareHandler))).onRequest fun response =>
      assertContains response "reached-inner"

def postWithSameLengthWrongTokenRejectedTest : IO Unit := do
  let store ← MemoryStore.new
  let (sid, token) ← establishToken store
  let wrongToken := String.ofList (token.toList.map fun c => if c == 'a' then 'b' else 'a')
  check "a same-length but wrong token is rejected 403"
    (mkPost "/" ""
      s!"X-CSRF-Token: {wrongToken}\x0d\nCookie: lean-session={sid}\x0d\nConnection: close\x0d\n")
    (cookies (session store {} (antiForgery {} bareHandler))).onRequest fun response =>
      assertStatus response "HTTP/1.1 403"

def postWithShortWrongTokenRejectedTest : IO Unit := do
  let store ← MemoryStore.new
  let (sid, _) ← establishToken store
  check "a different-length wrong token is rejected 403"
    (mkPost "/" "" s!"X-CSRF-Token: abc\x0d\nCookie: lean-session={sid}\x0d\nConnection: close\x0d\n")
    (cookies (session store {} (antiForgery {} bareHandler))).onRequest fun response =>
      assertStatus response "HTTP/1.1 403"

def safeHeaderBypassesValidationTest : IO Unit :=
  check "a configured safeHeader, present and non-blank, bypasses validation entirely"
    (mkPost "/" "" "X-Requested-With: xhr\x0d\nConnection: close\x0d\n")
    (antiForgery ({ safeHeader := some (Header.Name.mk "x-requested-with") } : AntiForgeryOptions)
      bareHandler).onRequest fun response => assertContains response "reached-inner"

def missingSafeHeaderStillRejectedTest : IO Unit :=
  check "without that header present, the same request is still rejected"
    (mkPost "/" "" "Connection: close\x0d\n")
    (antiForgery ({ safeHeader := some (Header.Name.mk "x-requested-with") } : AntiForgeryOptions)
      bareHandler).onRequest fun response => assertStatus response "HTTP/1.1 403"

def blankSafeHeaderStillRejectedTest : IO Unit :=
  check "a present but blank safeHeader value doesn't count as safe"
    (mkPost "/" "" "X-Requested-With: \x0d\nConnection: close\x0d\n")
    (antiForgery ({ safeHeader := some (Header.Name.mk "x-requested-with") } : AntiForgeryOptions)
      bareHandler).onRequest fun response => assertStatus response "HTTP/1.1 403"

def customErrorHandlerTest : IO Unit :=
  check "a custom errorHandler replaces the default HTML 403"
    (mkPost "/" "" "Connection: close\x0d\n")
    (antiForgery ({ errorHandler := jsonErrorHandler } : AntiForgeryOptions) bareHandler).onRequest
    fun response => do
      assertStatus response "HTTP/1.1 403"
      assertContains response "\"error\":\"forbidden\""
      assertAbsent response "Invalid anti-forgery token"

def tokenStableAcrossRequestsTest : IO Unit := do
  let store ← MemoryStore.new
  let (sid, token) ← establishToken store
  check "presenting the already-established token again issues no new Set-Cookie"
    (mkPost "/" "" s!"X-CSRF-Token: {token}\x0d\nCookie: lean-session={sid}\x0d\nConnection: close\x0d\n")
    (cookies (session store {} (antiForgery {} bareHandler))).onRequest fun response => do
      assertContains response "reached-inner"
      assertAbsent response "Set-Cookie"

def run : IO Unit :=
  runGroup "Middleware.AntiForgery" do
    safeMethodsPassWithoutSessionTest
    postWithoutSessionMiddlewareRejectedTest
    postNoStoredTokenRejectedTest
    postWithMatchingFormTokenSucceedsTest
    postWithCsrfHeaderTokenSucceedsTest
    postWithXsrfHeaderTokenSucceedsTest
    postWithSameLengthWrongTokenRejectedTest
    postWithShortWrongTokenRejectedTest
    safeHeaderBypassesValidationTest
    missingSafeHeaderStillRejectedTest
    blankSafeHeaderStillRejectedTest
    customErrorHandlerTest
    tokenStableAcrossRequestsTest

end Tests.AntiForgery
