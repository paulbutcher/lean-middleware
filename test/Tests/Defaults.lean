/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import Middleware
public import RoutingStd
public import Std.Http.Test.Helpers
public import Tests.Integration

public section

open Std.Http
open Routing
open Std.Http.Internal.Test
open Middleware (defaults apiDefaults secureApiDefaults siteDefaults secureSiteDefaults file
  MemoryStore SessionUpdate)
open Tests.Integration (extractCookieValue withFixtureDir throwingHandler notFoundHandler
  echoAntiForgeryTokenHandler reachedInnerHandler)

namespace Tests.Defaults

def okHandler : StatelessHandler .std :=
  { onRequest := fun _ => Response.ok |>.text "ok" }

def writeSessionHandler : StatelessHandler .std :=
  { onRequest := fun _ =>
      Response.ok |>.extension (SessionUpdate.write [("visited", "yes")]) |>.text "ok" }

def httpsHeader : String := "X-Forwarded-Proto: https\x0d\nConnection: close\x0d\n"

def secureApiRedirectsHttpTest : IO Unit :=
  check "secureApiDefaults redirects a request the proxy reports as http" (mkGetClose "/x")
    (defaults secureApiDefaults okHandler).onRequest fun response => do
      assertStatus response "HTTP/1.1 301"
      assertContains response "Location: https://example.com/x"

/-- `sslRedirect` sees the scheme only through `proxy`, so this is what fails if the preset ever
loses it: every request would redirect, `https` ones included. -/
def secureApiServesHttpsTest : IO Unit :=
  check "secureApiDefaults serves a request the proxy reports as https, with HSTS"
    (mkGet "/" httpsHeader) (defaults secureApiDefaults okHandler).onRequest fun response => do
      assertStatus response "HTTP/1.1 200"
      assertContains response "Strict-Transport-Security"

def siteSecurityHeadersSurviveCatchAllTest : IO Unit := do
  let store ← MemoryStore.new
  check "siteDefaults' security headers still apply to a 500 from catchAll" (mkGetClose "/")
    (defaults (siteDefaults store) throwingHandler).onRequest fun response => do
      assertStatus response "HTTP/1.1 500"
      assertContains response "X-Frame-Options: SAMEORIGIN"
      assertContains response "X-Content-Type-Options: nosniff"

def siteAntiForgeryRoundTripTest : IO Unit := do
  let store ← MemoryStore.new
  let stack := defaults (siteDefaults store)
  let cookieRef ← IO.mkRef (none : Option String)
  let tokenRef ← IO.mkRef (none : Option String)
  check "a GET through siteDefaults establishes a session and its token" (mkGetClose "/")
    (stack echoAntiForgeryTokenHandler).onRequest fun response => do
      cookieRef.set (extractCookieValue response "lean-session")
      tokenRef.set (some (String.fromUTF8! response |>.splitOn "\x0d\n\x0d\n" |>.getD 1 ""))
  match ← cookieRef.get, ← tokenRef.get with
  | none, _ => throw <| IO.userError "expected a Set-Cookie to be issued"
  | _, none => throw <| IO.userError "expected a token body to be captured"
  | some sid, some token =>
    check "a POST through siteDefaults without the token is refused"
      (mkPost "/" "" s!"Cookie: lean-session={sid}\x0d\nConnection: close\x0d\n")
      (stack reachedInnerHandler).onRequest fun response => assertStatus response "HTTP/1.1 403"
    check "a POST through siteDefaults with the token reaches the handler"
      (mkPost "/" s!"__anti-forgery-token={token}"
        s!"Content-Type: application/x-www-form-urlencoded\x0d\nCookie: lean-session={sid}\x0d\nConnection: close\x0d\n")
      (stack reachedInnerHandler).onRequest fun response =>
        assertContains response "reached-inner"

def secureSiteSessionCookieIsSecureTest : IO Unit := do
  let store ← MemoryStore.new
  check "secureSiteDefaults' session cookie is Secure" (mkGet "/" httpsHeader)
    (defaults (secureSiteDefaults store) writeSessionHandler).onRequest fun response => do
      let text := String.fromUTF8! response
      let some line := (text.splitOn "\x0d\n").find? (·.startsWith "Set-Cookie: secure-lean-session=")
        | throw <| IO.userError "expected the secure session cookie to be set"
      unless line.contains "Secure" do
        throw <| IO.userError s!"expected Secure on {line}"

/-- A slot standing in for `serverSpan`, which has to see an exception before `catchAll` turns it
into a response. -/
def recordingSlot (seen : IO.Ref Bool) : Middleware .std := fun handler =>
  { handler with
    onRequest := fun req => do
      try handler.onRequest req
      catch err =>
        seen.set true
        throw err }

def tracingSlotInsideCatchAllTest : IO Unit := do
  let seen ← IO.mkRef false
  check "the tracing slot sees an exception before catchAll answers it" (mkGetClose "/")
    (defaults { apiDefaults with tracing := recordingSlot seen } throwingHandler).onRequest
    fun response => assertStatus response "HTTP/1.1 500"
  unless ← seen.get do
    throw <| IO.userError "the tracing slot never saw the exception"

def staticSlotInsideContentTypeTest : IO Unit :=
  withFixtureDir fun dir =>
    check "a file from the static slot gets its Content-Type" (mkGetClose "/hello.txt")
      (defaults { apiDefaults with static := file dir } notFoundHandler).onRequest
      fun response => do
        assertStatus response "HTTP/1.1 200"
        assertContains response "Content-Type: text/plain"

def run : IO Unit :=
  runGroup "Defaults" do
    secureApiRedirectsHttpTest
    secureApiServesHttpsTest
    siteSecurityHeadersSurviveCatchAllTest
    siteAntiForgeryRoundTripTest
    secureSiteSessionCookieIsSecureTest
    tracingSlotInsideCatchAllTest
    staticSlotInsideContentTypeTest

end Tests.Defaults
