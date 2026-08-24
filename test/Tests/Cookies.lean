/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import Middleware.Cookies
public import Std.Http.Test.Helpers
public import Plausible

public section

open Std.Http
open Std.Http.Server
open Std.Http.Internal.Test
open Middleware (cookies Cookies SetCookie SetCookies CookieAttrs SameSite appendSetCookie)

namespace Tests.Cookies

def echoCookiesHandler : StatelessHandler :=
  { onRequest := fun req => do
      let pairs := (req.extensions.get Cookies).getD {} |>.pairs
      let summary := String.intercalate ";" (pairs.map fun (k, v) => s!"{k}={v}")
      Response.ok |>.text summary }

def twoCookiesHandler : StatelessHandler :=
  { onRequest := fun _ => do
      let resp ← Response.ok |>.text "set"
      let resp := appendSetCookie resp { name := "a", value := "1" }
      let resp := appendSetCookie resp { name := "b", value := "2" }
      pure resp }

def attrsCookieHandler : StatelessHandler :=
  { onRequest := fun _ => do
      let resp ← Response.ok |>.text "set"
      pure (appendSetCookie resp
        { name := "session", value := "xyz",
          attrs :=
            { path := some "/", domain := some "example.com", maxAge := some 3600,
              secure := true, httpOnly := true, sameSite := some .lax } }) }

def parsesCookieHeaderTest : IO Unit :=
  check "Cookie header parses into multiple pairs"
    (mkGet "/" "Cookie: a=1; b=2\x0d\nConnection: close\x0d\n")
    (cookies echoCookiesHandler).onRequest fun response => do
      assertContains response "a=1"
      assertContains response "b=2"

def malformedCookiePairDroppedTest : IO Unit :=
  check "a pair with no '=' is dropped, not fatal"
    (mkGet "/" "Cookie: a=1; bogus; b=2\x0d\nConnection: close\x0d\n")
    (cookies echoCookiesHandler).onRequest fun response => do
      assertStatus response "HTTP/1.1 200"
      assertContains response "a=1"
      assertContains response "b=2"
      assertAbsent response "bogus"

def noCookieHeaderTest : IO Unit :=
  check "no Cookie header yields an empty Cookies extension" (mkGetClose "/")
    (cookies echoCookiesHandler).onRequest fun response => do
      assertStatus response "HTTP/1.1 200"
      assertContains response "Content-Length: 0"

def multipleSetCookiesProduceSeparateHeadersTest : IO Unit :=
  check "two cookies become two distinct Set-Cookie: lines, not one comma-joined line"
    (mkGetClose "/") (cookies twoCookiesHandler).onRequest fun response => do
      let text := String.fromUTF8! response
      let occurrences := (text.splitOn "Set-Cookie:").length - 1
      unless occurrences == 2 do
        throw <| IO.userError s!"expected 2 Set-Cookie: lines, found {occurrences} in:\n{text}"
      assertContains response "a=1"
      assertContains response "b=2"

def attrsRenderedTest : IO Unit :=
  check "cookie attributes render on the wire" (mkGetClose "/")
    (cookies attrsCookieHandler).onRequest fun response => do
      assertContains response "session="
      assertContains response "Path=/"
      assertContains response "Domain=example.com"
      assertContains response "Max-Age=3600"
      assertContains response "Secure"
      assertContains response "HttpOnly"
      assertContains response "SameSite=Lax"

/-- `SetCookie.serialize` then `SetCookie.parse` recovers the original value, and the serialized
header still consists of exactly the one `name=value` part -- an application-supplied value can
never smuggle in a `Set-Cookie` attribute of its own, whatever characters it contains. -/
def cookieValueRoundtripHolds (value : String) : Bool :=
  let wire := (SetCookie.serialize { name := "x", value }).snd
  match SetCookie.parse wire with
  | some sc => sc.value == value && (wire.value.splitOn ";").length == 1
  | none => false

def cookieValueRoundtripTest : IO Unit := do
  match ← Plausible.Testable.checkIO
      (Plausible.NamedBinder "value" <| ∀ value : String, cookieValueRoundtripHolds value = true) with
  | .success _ => pure ()
  | .gaveUp n => throw <| IO.userError s!"gave up after {n} tries"
  | .failure _ steps _ => throw <| IO.userError s!"counter-example found: {steps}"

/-- The same property against values chosen to attack it, since `Plausible`'s own generator is
very unlikely to produce a value that looks like an attribute list in the first place. -/
def craftedValuesCannotInjectAttributesTest : IO Unit := do
  let values :=
    [ "", "plain", "a; Domain=evil.example", "a; HttpOnly", "a=b; Path=/", "a,b",
      "spaces and \"quotes\"", "%3B", "+", "already%20encoded" ]
  for value in values do
    unless cookieValueRoundtripHolds value do
      let wire := (SetCookie.serialize { name := "x", value }).snd
      throw <| IO.userError s!"value {value.quote} serialized unsafely as: {wire.value.quote}"

/-- A control character in the `name` or in an attribute still yields a `Set-Cookie` that carries
the cookie, rather than an empty header, and still can't smuggle in an attribute of its own. -/
def controlCharactersStillSerializeTest : IO Unit := do
  let cookie : SetCookie :=
    { name := "sid\x0d\nX-Evil: 1", value := "abc",
      attrs := { path := some "/app\x0d\n; HttpOnly" } }
  let wire := (SetCookie.serialize cookie).snd
  unless (wire.value.splitOn ";").length == 2 do
    throw <| IO.userError s!"expected exactly one attribute in: {wire.value.quote}"
  match SetCookie.parse wire with
  | none => throw <| IO.userError s!"didn't parse back: {wire.value.quote}"
  | some sc => do
    unless sc.value == "abc" do
      throw <| IO.userError s!"cookie value came back as {sc.value.quote}"
    unless !sc.name.isEmpty && sc.name.toList.all Std.Http.Internal.Char.tchar do
      throw <| IO.userError s!"cookie name came back as {sc.name.quote}"

def run : IO Unit :=
  runGroup "Middleware.Cookies" do
    parsesCookieHeaderTest
    malformedCookiePairDroppedTest
    noCookieHeaderTest
    multipleSetCookiesProduceSeparateHeadersTest
    attrsRenderedTest
    cookieValueRoundtripTest
    craftedValuesCannotInjectAttributesTest
    controlCharactersStillSerializeTest

end Tests.Cookies
