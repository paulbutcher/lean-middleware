/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Middleware.Session
import Middleware.Crypto.Base64
import MiddlewareCookieStore.AesGcm

namespace Middleware

namespace CookieStore

private def pushU32BE (arr : ByteArray) (n : UInt32) : ByteArray :=
  arr.push (n >>> 24).toUInt8 |>.push (n >>> 16).toUInt8 |>.push (n >>> 8).toUInt8 |>.push n.toUInt8

/-- A length-prefixed encoding of a `Session`'s key/value pairs (byte counts, not delimiters) --
deliberately not a text-escaping scheme: this project has already hit a real bug from exactly
that (`+`-vs-space ambiguity in `Cookies.lean`'s early cookie-value encoding), and a
length-prefixed format has no characters to escape in the first place. -/
def serialize (data : Session) : ByteArray :=
  data.foldl (init := pushU32BE ByteArray.empty data.length.toUInt32) fun acc (k, v) =>
    let kBytes := k.toUTF8
    let vBytes := v.toUTF8
    let acc := pushU32BE acc kBytes.size.toUInt32
    let acc := acc ++ kBytes
    let acc := pushU32BE acc vBytes.size.toUInt32
    acc ++ vBytes

private def readU32BE (arr : ByteArray) (off : Nat) : Option UInt32 :=
  if off + 4 ≤ arr.size then
    some
      ((arr.get! off).toUInt32 <<< 24 ||| (arr.get! (off + 1)).toUInt32 <<< 16 |||
        (arr.get! (off + 2)).toUInt32 <<< 8 ||| (arr.get! (off + 3)).toUInt32)
  else none

private def readString (arr : ByteArray) (off : Nat) : Option (String × Nat) := do
  let len ← readU32BE arr off
  let start := off + 4
  let stop := start + len.toNat
  if stop ≤ arr.size then
    let s ← String.fromUTF8? (arr.extract start stop)
    some (s, stop)
  else none

private def readPairs (arr : ByteArray) (off : Nat) : Nat → Option (Session × Nat)
  | 0 => some ([], off)
  | n + 1 => do
    let (key, off) ← readString arr off
    let (value, off) ← readString arr off
    let (rest, off) ← readPairs arr off n
    some ((key, value) :: rest, off)

/-- The inverse of `serialize`. `none` on any malformed input (truncated, a length prefix past
the end of the buffer, or bytes that aren't valid UTF-8) -- always the case for a genuinely
tampered blob, but such a blob never reaches here in practice since `aes256GcmOpen`'s
authentication already rejects it first. -/
def deserialize (arr : ByteArray) : Option Session := do
  let count ← readU32BE arr 0
  let (session, _) ← readPairs arr 4 count.toNat
  some session

end CookieStore

/-- Options for `CookieStore`. -/
structure CookieStoreOptions where
  /-- The AES-256 key to encrypt sessions with. `none` mints a fresh random one at
  `CookieStore.new` time -- convenient for development or a single-process deployment, but a
  restart then invalidates every outstanding session. A multi-instance or restart-tolerant
  deployment should configure one. -/
  key : Option ByteArray := none

/-- A `SessionStore` that keeps no server-side state at all: the session data is serialized,
AES-256-GCM sealed, and the sealed blob itself (base64-encoded) becomes the cookie's value.
`read`/`write` treat the `String` `session` threads through as that value directly rather than as
a lookup key into anything -- `SessionStore`'s signature already supports this (`MemoryStore`
just happens to use it the other way). -/
structure CookieStore where
  key : ByteArray

def CookieStore.new (options : CookieStoreOptions := {}) : IO CookieStore := do
  pure { key := ← options.key.getDM Crypto.genKey }

instance : SessionStore CookieStore where
  read store sealedValue := do
    let some raw := Crypto.Base64.decode sealedValue | pure none
    if raw.size < 12 then
      pure none
    else
      let nonce := raw.extract 0 12
      let sealed := raw.extract 12 raw.size
      match Crypto.aes256GcmOpen store.key nonce sealed with
      | none => pure none
      | some plaintext => pure (CookieStore.deserialize plaintext)
  write store _existingKey data := do
    let nonce ← Crypto.genNonce
    let sealed := Crypto.aes256GcmSeal store.key nonce (CookieStore.serialize data)
    pure (Crypto.Base64.encode (nonce ++ sealed))
  delete _store _key := pure ()
    -- No server-side state to remove; `session`'s own expiring `Set-Cookie` already handles
    -- clearing the client's copy.

end Middleware
