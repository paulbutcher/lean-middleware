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

/--
Removing one key from a session leaves every lookup of a different key answering exactly as it
did before. This is the arithmetic the other session theorems rest on: `Session.set` is defined
as a filter followed by a cons, so nothing can be said about how `set` treats an untouched key
without first knowing that the filter does not disturb it.

For any session `s` and any two keys `k` and `k'` with `k'` distinct from `k`, searching the
list filtered down to the pairs whose first component differs from `k` for a pair whose first
component is `k'` finds the same thing as searching the unfiltered `s`. The hypothesis `k' ≠ k`
is what makes this non-trivial rather than vacuous: without it the two sides differ precisely
when `s` binds `k`.
-/
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

/--
A session reads back what was last written to it. This is the base guarantee an application
relies on every time it stores something in a session and expects to find it on the next request,
and it holds whatever the session already contained, including a prior binding for the same key.

For any session `s`, key `k` and value `v`, looking `k` up in `Session.set s k v` yields
`some v`. Since `set` conses the new pair onto the front of the filtered list and `get` returns
the first match, this says the fresh binding shadows anything `s` held for `k`, not merely that
some binding for `k` exists.
-/
theorem get_set_self (s : Session) (k v : String) : (Session.set s k v).get k = some v := by
  simp [Session.set, Session.get]

/--
Removing a key really removes it, rather than leaving an older binding for the same key exposed
underneath. That matters because `Session.set` prepends: a key written twice would leave two
pairs in the list if `set` did not filter, and a `remove` that stripped only the first would
resurrect the earlier value.

For any session `s` and key `k`, looking `k` up in `Session.remove s k` yields `none`. As
`remove` is a filter over the whole list rather than a search-and-delete, this holds however many
times `k` appears in `s`.
-/
theorem get_remove_self (s : Session) (k : String) : (Session.remove s k).get k = none := by
  simp [Session.remove, Session.get]

/--
Writing one key never disturbs another, so the reserved keys `flash` and `antiForgery` keep
inside the session survive an application's own writes, and vice versa. Without this, two
middleware sharing one session would be free to clobber each other's bookkeeping.

For any session `s`, any key `k` being written with value `v`, and any other key `k'` distinct
from `k`, looking `k'` up after the write gives exactly what it gave before. The hypothesis
`k' ≠ k` is the whole content of the claim: it is what separates "another key" from the key just
written, whose value `get_set_self` covers instead.
-/
theorem get_set_of_ne (s : Session) (k k' v : String) (h : k' ≠ k) :
    (Session.set s k v).get k' = s.get k' := by
  simp [Session.set, Session.get, Ne.symm h, find?_filter_ne s k k' h]

/--
Repeatedly writing the same key replaces rather than accumulates, so a long-lived session can't
grow without bound. That matters most for `CookieStore`, where the whole session has to fit in a
cookie and an append-only session would eventually stop being sendable at all.

For any session `s`, key `k` and values `v₁` and `v₂`, setting `k` to `v₁` and then to `v₂` gives
a session equal to setting `k` to `v₂` once. This is equality of the session lists themselves,
not just of what `get` reports, which is what makes it a statement about size rather than only
about lookups.
-/
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

/-- `session` reads its id from the `Cookies` extension, so without `cookies` outside it there is
no cookie to read and every request would look like a first visit: a new session minted each
time, and nothing ever read back. Refusing says which layer is missing instead of presenting
that as ordinary behaviour. -/
def refusesWithoutCookiesTest : IO Unit := do
  let store ← MemoryStore.new
  let entered ← IO.mkRef false
  let handler : StatelessHandler :=
    { onRequest := fun _ => do
        entered.set true
        Response.ok |>.text "reached" }
  check "session answers 500 when `cookies` isn't in the stack" (mkGetClose "/")
    (session store {} handler).onRequest fun response => do
      assertStatus response "HTTP/1.1 500"
      assertAbsent response "reached"
  if ← entered.get then
    throw <| IO.userError "expected the wrapped handler not to run at all"

def run : IO Unit :=
  runGroup "Middleware.Session" do
    sessionRoundtripTest
    noWriteNoStoreChangeTest
    unknownSessionCookieTest
    deleteSessionRemovesFromStoreTest
    customCookieNameTest
    genSessionIdShapeTest
    genSessionIdUniquenessTest
    refusesWithoutCookiesTest

end Tests.Session
