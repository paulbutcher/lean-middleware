/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

import Libcrypto.Aead

public section

namespace Middleware.Crypto

private def algorithm : Libcrypto.Aead.Algorithm := .aes256Gcm

/-- Seals `plaintext` under AES-256-GCM with the given `key` and `nonce`, returning the ciphertext
with the authentication tag appended. The two are kept apart underneath; joining them here is what
makes the sealed blob a single cookie value. -/
def aes256GcmSeal (key nonce plaintext : ByteArray) : IO ByteArray := do
  let sealed ← Libcrypto.Aead.encrypt algorithm key nonce ByteArray.empty plaintext
  return sealed.ciphertext ++ sealed.tag

/-- Opens a blob produced by `aes256GcmSeal` with the same `key`/`nonce`, returning `none` if
`sealed` is too short to contain a tag or the tag doesn't authenticate it (tampered, or a different
key or nonce). A key of the wrong length is a caller error rather than a failure to authenticate,
and throws. -/
def aes256GcmOpen (key nonce sealed : ByteArray) : IO (Option ByteArray) := do
  if sealed.size < algorithm.tagLength then
    return none
  let body := sealed.size - algorithm.tagLength
  Libcrypto.Aead.decrypt algorithm key nonce ByteArray.empty
    { ciphertext := sealed.extract 0 body, tag := sealed.extract body sealed.size }

/-- A fresh random AES-256 key. -/
def genKey : IO ByteArray := IO.getRandomBytes algorithm.keyLength.toUSize

/-- A fresh random GCM nonce (the standard 96-bit size). -/
def genNonce : IO ByteArray := IO.getRandomBytes algorithm.nonceLength.toUSize

end Middleware.Crypto
