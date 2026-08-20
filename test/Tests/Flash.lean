/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import Middleware.Cookies
public import Middleware.Session
public import Middleware.Flash
public import Std.Http.Test.Helpers

public section

open Std.Http
open Std.Http.Server
open Std.Http.Internal.Test
open Middleware (cookies session flash MemoryStore SessionStore SessionData SessionUpdate
  Session Flash FlashMessage)

namespace Tests.Flash

/-- Extracts a cookie's raw wire value from a `Set-Cookie:` response line, if present. -/
def extractCookieValue (response : ByteArray) (name : String) : Option String :=
  let text := String.fromUTF8! response
  let prefix_ := s!"Set-Cookie: {name}="
  match (text.splitOn "\x0d\n").find? (·.startsWith prefix_) with
  | none => none
  | some line => some ((line.drop prefix_.length).toString.splitOn ";" |>.headD "")

def setFlashHandler : StatelessHandler :=
  { onRequest := fun _ =>
      Response.ok |>.extension (FlashMessage.mk "hello") |>.text "flash-set" }

def readFlashHandler : StatelessHandler :=
  { onRequest := fun req => do
      let message := (req.extensions.get Flash).getD {} |>.message
      Response.ok |>.text (message.getD "<none>") }

/-- Reads the flash message and, unlike `readFlashHandler`, also persists the (already
flash-stripped) session it received -- the pattern a real application needs so the message
is genuinely delivered once, not left sitting in the store (see `flash`'s doc comment). -/
def readFlashAndPersistHandler : StatelessHandler :=
  { onRequest := fun req => do
      let sessionData := (req.extensions.get SessionData).getD {}
      let message := (req.extensions.get Flash).getD {} |>.message
      Response.ok
        |>.extension (SessionUpdate.write sessionData.data)
        |>.text (message.getD "<none>") }

def setFlashAndSessionHandler : StatelessHandler :=
  { onRequest := fun _ =>
      Response.ok
        |>.extension (SessionUpdate.write [("other", "x")])
        |>.extension (FlashMessage.mk "next")
        |>.text "both-set" }

def readSessionKeyHandler (key : String) : StatelessHandler :=
  { onRequest := fun req => do
      let data := (req.extensions.get SessionData).getD {} |>.data
      Response.ok |>.text (data.get key |>.getD "<missing>") }

def flashDeliveredOnceWhenConsumerPersistsTest : IO Unit := do
  let store ← MemoryStore.new
  let cookieRef ← IO.mkRef (none : Option String)
  check "setting a flash message" (mkGetClose "/")
    (cookies (session store {} (flash setFlashHandler))).onRequest fun response =>
      cookieRef.set (extractCookieValue response "lean-session")
  match ← cookieRef.get with
  | none => throw <| IO.userError "expected a Set-Cookie to be issued"
  | some sid => do
    check "the very next request sees the flash message and persists it as consumed"
      (mkGet "/" s!"Cookie: lean-session={sid}\x0d\nConnection: close\x0d\n")
      (cookies (session store {} (flash readFlashAndPersistHandler))).onRequest fun response =>
        assertContains response "hello"
    check "a later request no longer sees it"
      (mkGet "/" s!"Cookie: lean-session={sid}\x0d\nConnection: close\x0d\n")
      (cookies (session store {} (flash readFlashHandler))).onRequest fun response =>
        assertContains response "<none>"

def flashSurvivesIfConsumerDoesNotPersistTest : IO Unit := do
  let store ← MemoryStore.new
  let cookieRef ← IO.mkRef (none : Option String)
  check "setting a flash message" (mkGetClose "/")
    (cookies (session store {} (flash setFlashHandler))).onRequest fun response =>
      cookieRef.set (extractCookieValue response "lean-session")
  match ← cookieRef.get with
  | none => throw <| IO.userError "expected a Set-Cookie to be issued"
  | some sid => do
    check "a request that reads but doesn't persist leaves the store's copy untouched"
      (mkGet "/" s!"Cookie: lean-session={sid}\x0d\nConnection: close\x0d\n")
      (cookies (session store {} (flash readFlashHandler))).onRequest fun response =>
        assertContains response "hello"
    check "so it's still there on the request after that too: flash only clears from the store \
on a request whose response itself performs a session write"
      (mkGet "/" s!"Cookie: lean-session={sid}\x0d\nConnection: close\x0d\n")
      (cookies (session store {} (flash readFlashHandler))).onRequest fun response =>
        assertContains response "hello"

def flashMergesWithExplicitSessionWriteTest : IO Unit := do
  let store ← MemoryStore.new
  let sid ← SessionStore.write store none []
  check "a handler that sets both flash and other session data gets both persisted together"
    (mkGet "/" s!"Cookie: lean-session={sid}\x0d\nConnection: close\x0d\n")
    (cookies (session store {} (flash setFlashAndSessionHandler))).onRequest fun response =>
      assertContains response "both-set"
  check "the non-flash key is readable back"
    (mkGet "/" s!"Cookie: lean-session={sid}\x0d\nConnection: close\x0d\n")
    (cookies (session store {} (readSessionKeyHandler "other"))).onRequest fun response =>
      assertContains response "x"
  check "the flash message is readable back on the request after that"
    (mkGet "/" s!"Cookie: lean-session={sid}\x0d\nConnection: close\x0d\n")
    (cookies (session store {} (flash readFlashHandler))).onRequest fun response =>
      assertContains response "next"

def flashPassthroughWhenUntouchedTest : IO Unit := do
  let store ← MemoryStore.new
  let sid ← SessionStore.write store none []
  check "a handler that sets neither flash nor session causes no Set-Cookie"
    (mkGet "/" s!"Cookie: lean-session={sid}\x0d\nConnection: close\x0d\n")
    (cookies (session store {} (flash readFlashHandler))).onRequest fun response => do
      assertContains response "<none>"
      assertAbsent response "Set-Cookie"

def run : IO Unit :=
  runGroup "Middleware.Flash" do
    flashDeliveredOnceWhenConsumerPersistsTest
    flashSurvivesIfConsumerDoesNotPersistTest
    flashMergesWithExplicitSessionWriteTest
    flashPassthroughWhenUntouchedTest

end Tests.Flash
