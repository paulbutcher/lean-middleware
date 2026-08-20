/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import Middleware.Cookies
public import Middleware.Session
public import Std.Http.Test.Helpers

public section

open Std.Http
open Std.Http.Server
open Std.Http.Internal.Test
open Middleware (cookies session MemoryStore SessionData SessionUpdate SessionOptions Session
  genSessionId)

namespace Tests.Session

private theorem find?_filter_ne (s : Session) (k k' : String) (h : k' ≠ k) :
    (s.filter (·.fst != k)).find? (·.fst == k') = s.find? (·.fst == k') := by
  induction s with
  | nil => rfl
  | cons hd tl ih =>
    by_cases hk : hd.fst = k
    · simp [hk, ih, Ne.symm h]
    · by_cases hk' : hd.fst = k'
      · simp [hk', h]
      · simp [hk, hk', ih]

theorem get_set_self (s : Session) (k v : String) : (Session.set s k v).get k = some v := by
  simp [Session.set, Session.get]

theorem get_remove_self (s : Session) (k : String) : (Session.remove s k).get k = none := by
  simp [Session.remove, Session.get]

/-- Writing one key never disturbs another, so the reserved keys `flash` and `antiForgery` keep
inside the session survive an application's own writes, and vice versa. -/
theorem get_set_of_ne (s : Session) (k k' v : String) (h : k' ≠ k) :
    (Session.set s k v).get k' = s.get k' := by
  simp [Session.set, Session.get, Ne.symm h, find?_filter_ne s k k' h]

/-- Repeatedly writing the same key replaces rather than accumulates, so a long-lived session
can't grow without bound. That matters most for `CookieStore`, where the whole session has to fit
in a cookie. -/
theorem set_set (s : Session) (k v₁ v₂ : String) :
    Session.set (Session.set s k v₁) k v₂ = Session.set s k v₂ := by
  simp [Session.set]

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

def sessionRoundtripTest : IO Unit := do
  let store ← MemoryStore.new
  let capturedCookie ← IO.mkRef (none : Option String)
  check "writing a session sets a Set-Cookie with a fresh id, default attrs applied"
    (mkGetClose "/") (cookies (session store {} writeSessionHandler)).onRequest fun response => do
      assertContains response "written"
      assertContains response "Path=/"
      assertContains response "HttpOnly"
      capturedCookie.set (extractCookieValue response "lean-session")
  match ← capturedCookie.get with
  | none => throw <| IO.userError "expected a Set-Cookie to be issued"
  | some sid =>
    check "presenting the session cookie reads the same data back from the store"
      (mkGet "/" s!"Cookie: lean-session={sid}\x0d\nConnection: close\x0d\n")
      (cookies (session store {} readSessionHandler)).onRequest fun response =>
        assertContains response "alice"

def noWriteNoStoreChangeTest : IO Unit := do
  let store ← MemoryStore.new
  check "a handler that never sets SessionUpdate causes no Set-Cookie" (mkGetClose "/")
    (cookies (session store {} noopHandler)).onRequest fun response => do
      assertContains response "noop"
      assertAbsent response "Set-Cookie"

def unknownSessionCookieTest : IO Unit := do
  let store ← MemoryStore.new
  check "an unrecognized session cookie reads back as an empty session, not a crash"
    (mkGet "/" "Cookie: lean-session=does-not-exist\x0d\nConnection: close\x0d\n")
    (cookies (session store {} readSessionHandler)).onRequest fun response => do
      assertStatus response "HTTP/1.1 200"
      assertContains response "<missing>"

def deleteSessionRemovesFromStoreTest : IO Unit := do
  let store ← MemoryStore.new
  let capturedCookie ← IO.mkRef (none : Option String)
  check "writing a session" (mkGetClose "/")
    (cookies (session store {} writeSessionHandler)).onRequest fun response =>
      capturedCookie.set (extractCookieValue response "lean-session")
  match ← capturedCookie.get with
  | none => throw <| IO.userError "expected a Set-Cookie to be issued"
  | some sid => do
    check "deleting the session expires the cookie" (mkGet "/" s!"Cookie: lean-session={sid}\x0d\nConnection: close\x0d\n")
      (cookies (session store {} deleteSessionHandler)).onRequest fun response => do
        assertContains response "deleted"
        assertContains response "Max-Age=0"
    check "the deleted session no longer reads back"
      (mkGet "/" s!"Cookie: lean-session={sid}\x0d\nConnection: close\x0d\n")
      (cookies (session store {} readSessionHandler)).onRequest fun response =>
        assertContains response "<missing>"

def customCookieNameTest : IO Unit := do
  let store ← MemoryStore.new
  check "a custom cookieName is used for the session cookie" (mkGetClose "/")
    (cookies (session store ({ cookieName := "sid" } : SessionOptions) writeSessionHandler)).onRequest
    fun response => do
      assertContains response "Set-Cookie: sid="
      assertAbsent response "Set-Cookie: lean-session="

def genSessionIdShapeTest : IO Unit := do
  let sid ← genSessionId
  unless sid.length == 64 do
    throw <| IO.userError s!"expected a 64-hex-char session id, got {sid.length} chars: {sid}"
  unless sid.toList.all (fun c => c.isDigit || ('A' ≤ c ∧ c ≤ 'F')) do
    throw <| IO.userError s!"expected only uppercase hex digits, got: {sid}"

def genSessionIdUniquenessTest : IO Unit := do
  let ids ← (List.range 20).mapM fun _ => genSessionId
  unless ids.eraseDups.length == 20 do
    throw <| IO.userError s!"expected 20 distinct session ids, got duplicates in: {ids}"

def run : IO Unit :=
  runGroup "Middleware.Session" do
    sessionRoundtripTest
    noWriteNoStoreChangeTest
    unknownSessionCookieTest
    deleteSessionRemovesFromStoreTest
    customCookieNameTest
    genSessionIdShapeTest
    genSessionIdUniquenessTest

end Tests.Session
