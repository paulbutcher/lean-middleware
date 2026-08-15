/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Middleware.CookieStore
import Middleware.Cookies
import Std.Http.Test.Helpers
import Plausible

open Std.Http
open Std.Http.Server
open Std.Http.Internal.Test
open Middleware (cookies session CookieStore SessionData SessionUpdate Session)
open Middleware.CookieStore (serialize deserialize)

namespace Tests.CookieStore

/-- Extracts a cookie's raw wire value from a `Set-Cookie:` response line, if present. -/
def extractCookieValue (response : ByteArray) (name : String) : Option String :=
  let text := String.fromUTF8! response
  let prefix_ := s!"Set-Cookie: {name}="
  match (text.splitOn "\x0d\n").find? (·.startsWith prefix_) with
  | none => none
  | some line => some ((line.drop prefix_.length).toString.splitOn ";" |>.headD "")

def writeSessionHandler : StatelessHandler :=
  { onRequest := fun _ =>
      Response.ok |>.extension (SessionUpdate.write [("user", "alice")]) |>.text "written" }

def readSessionHandler : StatelessHandler :=
  { onRequest := fun req => do
      let data := (req.extensions.get SessionData).getD {} |>.data
      Response.ok |>.text (data.get "user" |>.getD "<missing>") }

def deleteSessionHandler : StatelessHandler :=
  { onRequest := fun _ =>
      Response.ok |>.extension SessionUpdate.delete |>.text "deleted" }

def noopHandler : StatelessHandler :=
  { onRequest := fun _ => Response.ok |>.text "noop" }

/-- Unlike `MemoryStore`, there's no server-side table to keep the `session` middleware itself
correct -- this exercises the exact same `session` middleware code path, just with `CookieStore`
proving `SessionStore` genuinely is backend-agnostic, not just correct for the one instance
`Tests/Session.lean` covers. -/
def sessionRoundtripTest : IO Unit := do
  let store ← Middleware.CookieStore.new
  let capturedCookie ← IO.mkRef (none : Option String)
  check "writing a session sets a Set-Cookie with a sealed value" (mkGetClose "/")
    (cookies (session store {} writeSessionHandler)).onRequest fun response => do
      assertContains response "written"
      capturedCookie.set (extractCookieValue response "lean-session")
  match ← capturedCookie.get with
  | none => throw <| IO.userError "expected a Set-Cookie to be issued"
  | some sealed =>
    check "presenting the sealed cookie reads the same data back"
      (mkGet "/" s!"Cookie: lean-session={sealed}\x0d\nConnection: close\x0d\n")
      (cookies (session store {} readSessionHandler)).onRequest fun response =>
        assertContains response "alice"

def noWriteNoStoreChangeTest : IO Unit := do
  let store ← Middleware.CookieStore.new
  check "a handler that never sets SessionUpdate causes no Set-Cookie" (mkGetClose "/")
    (cookies (session store {} noopHandler)).onRequest fun response => do
      assertContains response "noop"
      assertAbsent response "Set-Cookie"

def garbageCookieValueTest : IO Unit := do
  let store ← Middleware.CookieStore.new
  check "a garbage (non-base64, or unsealable) cookie value reads back as an empty session"
    (mkGet "/" "Cookie: lean-session=not-a-real-sealed-value\x0d\nConnection: close\x0d\n")
    (cookies (session store {} readSessionHandler)).onRequest fun response => do
      assertStatus response "HTTP/1.1 200"
      assertContains response "<missing>"

/-- A cookie sealed under a *different* store's key is exactly as unreadable as one that was
never validly sealed at all -- proves the AES-GCM tag, not just the base64/length-prefix framing,
is what's actually gating access. -/
def tamperedCookieRejectedTest : IO Unit := do
  let store ← Middleware.CookieStore.new
  let otherStore ← Middleware.CookieStore.new
  let capturedCookie ← IO.mkRef (none : Option String)
  check "writing a session under one store's key" (mkGetClose "/")
    (cookies (session store {} writeSessionHandler)).onRequest fun response =>
      capturedCookie.set (extractCookieValue response "lean-session")
  match ← capturedCookie.get with
  | none => throw <| IO.userError "expected a Set-Cookie to be issued"
  | some sealed =>
    check "reading it back under a different store's key fails closed, not a crash"
      (mkGet "/" s!"Cookie: lean-session={sealed}\x0d\nConnection: close\x0d\n")
      (cookies (session otherStore {} readSessionHandler)).onRequest fun response => do
        assertStatus response "HTTP/1.1 200"
        assertContains response "<missing>"

def deleteSessionTest : IO Unit := do
  let store ← Middleware.CookieStore.new
  let capturedCookie ← IO.mkRef (none : Option String)
  check "writing a session" (mkGetClose "/")
    (cookies (session store {} writeSessionHandler)).onRequest fun response =>
      capturedCookie.set (extractCookieValue response "lean-session")
  match ← capturedCookie.get with
  | none => throw <| IO.userError "expected a Set-Cookie to be issued"
  | some sealed =>
    check "deleting that session expires the cookie without error"
      (mkGet "/" s!"Cookie: lean-session={sealed}\x0d\nConnection: close\x0d\n")
      (cookies (session store {} deleteSessionHandler)).onRequest fun response => do
        assertContains response "deleted"
        assertContains response "Max-Age=0"

def serializeRoundtripHolds (data : Session) : Bool :=
  deserialize (serialize data) == some data

def serializeRoundtripTest : IO Unit := do
  match ← Plausible.Testable.checkIO
      (Plausible.NamedBinder "data" <| ∀ data : List (String × String),
        serializeRoundtripHolds data = true) with
  | .success _ => pure ()
  | .gaveUp n => throw <| IO.userError s!"gave up after {n} tries"
  | .failure _ steps _ => throw <| IO.userError s!"counter-example found: {steps}"

/-- The whole point of the length-prefixed framing is that there's nothing to escape, so these
are the keys and values a delimiter-based format would have got wrong. -/
def awkwardKeysAndValuesRoundtripTest : IO Unit := do
  let cases : List Session :=
    [ [],
      [("", "")],
      [("k", "a;b"), ("k2", "a=b"), ("k3", "a&b+c")],
      [("k", "line1\nline2\r\n")],
      [("キー", "日本語の値 ✅")],
      [("dup", "first"), ("dup", "second")],
      [("k", String.ofList (List.replicate 5000 'x'))] ]
  for data in cases do
    unless serializeRoundtripHolds data do
      throw <| IO.userError s!"session {repr data} did not survive serialize/deserialize"

/-- Every proper prefix of a serialized session is rejected outright rather than deserializing to
a partial session or reading past the end of the buffer. A tampered blob can't reach here in
practice (`aes256GcmOpen` authenticates first), so this is the only thing exercising
`deserialize`'s bounds checks at all. -/
def truncatedBlobRejectedTest : IO Unit := do
  let blob := serialize [("user", "alice"), ("role", "admin")]
  for len in [0:blob.size] do
    unless deserialize (blob.extract 0 len) == none do
      throw <| IO.userError
        s!"expected a {len}-byte truncation of a {blob.size}-byte blob to be rejected"

/-- A length prefix pointing past the end of the buffer is rejected too, rather than being used
as an unchecked index. -/
def oversizedLengthPrefixRejectedTest : IO Unit := do
  let blob := serialize [("user", "alice")]
  let corrupted := ByteArray.mk (blob.toList.set 4 0xFF).toArray
  unless deserialize corrupted == none do
    throw <| IO.userError "expected a length prefix past the end of the buffer to be rejected"

def run : IO Unit :=
  runGroup "Middleware.CookieStore" do
    sessionRoundtripTest
    noWriteNoStoreChangeTest
    garbageCookieValueTest
    tamperedCookieRejectedTest
    deleteSessionTest
    serializeRoundtripTest
    awkwardKeysAndValuesRoundtripTest
    truncatedBlobRejectedTest
    oversizedLengthPrefixRejectedTest

end Tests.CookieStore
