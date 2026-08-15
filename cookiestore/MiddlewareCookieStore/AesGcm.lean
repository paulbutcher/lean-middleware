/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

namespace Middleware.Crypto

/-- Seals `plaintext` under AES-256-GCM with the given `key` (32 bytes) and `nonce` (12 bytes),
returning the ciphertext with the 16-byte authentication tag appended. `key`/`nonce` must be
exactly those lengths -- an internal primitive, not hardened against a hostile caller; the only
caller (`Middleware.CookieStore`) always generates them at the right size itself. -/
@[extern "lean_aes256_gcm_seal"]
opaque aes256GcmSeal (key nonce plaintext : ByteArray) : ByteArray

/-- Opens a blob produced by `aes256GcmSeal` with the same `key`/`nonce`, returning `none` if the
key/nonce are the wrong length, `sealed` is too short to contain a tag, or the authentication tag
doesn't match (tampered or wrong key/nonce). -/
@[extern "lean_aes256_gcm_open"]
opaque aes256GcmOpen (key nonce sealed : ByteArray) : Option ByteArray

/-- A fresh random AES-256 key. -/
def genKey : IO ByteArray := IO.getRandomBytes 32

/-- A fresh random GCM nonce (the standard 96-bit size). -/
def genNonce : IO ByteArray := IO.getRandomBytes 12

end Middleware.Crypto
