/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import Middleware.Cookies

public section

open Std.Http
open Std.Http.Server

namespace Middleware

/-- Server-side session data: an arbitrary string-keyed, string-valued map. -/
abbrev Session := List (String × String)

namespace Session

@[expose] def get (s : Session) (key : String) : Option String :=
  (s.find? (·.fst == key)).map Prod.snd

@[expose] def set (s : Session) (key value : String) : Session :=
  (key, value) :: s.filter (·.fst != key)

@[expose] def remove (s : Session) (key : String) : Session :=
  s.filter (·.fst != key)

end Session

/-- A pluggable session-storage backend. `write` mints and returns a fresh key when `key` is
`none` (a brand-new session); otherwise it updates the session under `key`, still returning it. -/
class SessionStore (σ : Type) where
  read : σ → String → IO (Option Session)
  write : σ → Option String → Session → IO String
  delete : σ → String → IO Unit

private def toHex (bytes : ByteArray) : String :=
  String.ofList (bytes.toList.flatMap fun b =>
    [Char.ofNat (URI.hexDigit (b / 16)).toNat, Char.ofNat (URI.hexDigit (b % 16)).toNat])

/-- Generates an unpredictable session id: 256 bits of OS entropy (`IO.getRandomBytes`, not the
seeded general-purpose PRNG in `Init.Data.Random`, which is unsuitable for anything
security-sensitive), hex-encoded. -/
def genSessionId : IO String := do
  let bytes ← IO.getRandomBytes 32
  pure (toHex bytes)

/-- An in-memory `SessionStore`. No expiry or eviction, so a long-lived process accumulates
sessions forever unless something else deletes them. Fine for development, testing, or a
single-process deployment with a bounded user base; anything else should implement its own
`SessionStore`. -/
structure MemoryStore where
  ref : IO.Ref (List (String × Session))

def MemoryStore.new : IO MemoryStore := do
  pure { ref := ← IO.mkRef [] }

instance : SessionStore MemoryStore where
  read store key := do pure ((← store.ref.get).find? (·.fst == key) |>.map Prod.snd)
  write store key data := do
    let k ← match key with
      | some k => pure k
      | none => genSessionId
    store.ref.modify fun m => (k, data) :: m.filter (·.fst != k)
    pure k
  delete store key := store.ref.modify fun m => m.filter (·.fst != key)

/-- Options for `session`. -/
structure SessionOptions where
  cookieName : String := "lean-session"
  cookieAttrs : CookieAttrs := { path := some "/", httpOnly := true }

/-- The session loaded for this request (empty if no valid session cookie was presented). -/
structure SessionData where
  key : Option String := none
  data : Session := []
deriving TypeName

/-- What to do with the session on the way out. Absent (or `.unchanged`) leaves storage and
cookies untouched; set explicitly via `Response.Builder.extension` to persist a change. -/
inductive SessionUpdate where
  | unchanged
  | write (data : Session)
  | delete
deriving TypeName

/-- Loads the session named by `options.cookieName` (via the `Cookies` extension, so `cookies`
must be wrapped outer; a stack without it is refused by `missingLayer` rather than read as a
request that simply carried no session cookie) into a `SessionData` request extension, and
applies any `SessionUpdate` the handler (or `flash`, on its behalf) attaches to the response:
persisting a `.write`, deleting on `.delete`, and either way appending the session-id cookie via
`appendSetCookie` for `cookies` to actually send. -/
def session [SessionStore σ] (store : σ) (options : SessionOptions := {}) : Middleware :=
  fun handler =>
    { handler with
      onRequest := fun req => do
        let some cookies := req.extensions.get Cookies
          | (missingLayer "cookies" "session").onRequest req
        let key := cookies.get options.cookieName
        let data ← match key with
          | some k => pure ((← SessionStore.read store k).getD [])
          | none => pure []
        let req := { req with extensions := req.extensions.insert ({ key, data } : SessionData) }
        let resp ← handler.onRequest req
        match resp.extensions.get SessionUpdate with
        | none | some .unchanged => pure resp
        | some (.write newData) => do
          let newKey ← SessionStore.write store key newData
          pure (appendSetCookie resp
            { name := options.cookieName, value := newKey, attrs := options.cookieAttrs })
        | some .delete => do
          match key with
          | none => pure resp
          | some k => do
            SessionStore.delete store k
            pure (appendSetCookie resp
              { name := options.cookieName, value := "",
                attrs := { options.cookieAttrs with maxAge := some 0 } }) }

end Middleware
