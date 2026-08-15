/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import MiddlewareCookieStore.AesGcm
import Std.Http.Test.Helpers

open Middleware.Crypto
open Std.Http.Internal.Test (runGroup)

namespace Tests.Crypto.AesGcm

private def hexDigit (c : Char) : Nat :=
  if '0' ≤ c ∧ c ≤ '9' then c.toNat - '0'.toNat else (c.toNat - 'a'.toNat) + 10

private def hexToBytesGo : List Char → List UInt8
  | c0 :: c1 :: rest => (hexDigit c0 * 16 + hexDigit c1).toUInt8 :: hexToBytesGo rest
  | _ => []

/-- Decodes a lowercase hex literal into bytes. A test-fixture-only helper -- not validated
against malformed input, since every call site here is a hardcoded, known-good vector. -/
def hexToBytes (s : String) : ByteArray :=
  ByteArray.mk (hexToBytesGo s.toList).toArray

private def check (name : String) (cond : Bool) : IO Unit :=
  unless cond do throw <| IO.userError s!"{name} failed"

/-- NIST-derived AES-256-GCM vectors with empty AAD (our binding has no AAD parameter), taken
verbatim from OpenSSL's own EVP test suite
(`test/recipes/30-test_evp_data/evpciph_aes_common.txt`), which cites the original GCM
specification (McGrew & Viega) and NIST's CAVP program as its source. -/
structure Vector where
  key : String
  iv : String
  tag : String
  plaintext : String
  ciphertext : String

def vectors : List Vector := [
  { key := "0000000000000000000000000000000000000000000000000000000000000000",
    iv := "000000000000000000000000",
    tag := "530f8afbc74536b9a963b4f1c4cb738b",
    plaintext := "",
    ciphertext := "" },
  { key := "0000000000000000000000000000000000000000000000000000000000000000",
    iv := "000000000000000000000000",
    tag := "d0d1c8a799996bf0265b98b5d48ab919",
    plaintext := "00000000000000000000000000000000",
    ciphertext := "cea7403d4d606b6e074ec5d3baf39d18" },
  { key := "feffe9928665731c6d6a8f9467308308feffe9928665731c6d6a8f9467308308",
    iv := "cafebabefacedbaddecaf888",
    tag := "b094dac5d93471bdec1a502270e3cc6c",
    plaintext :=
      "d9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a721c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b391aafd255",
    ciphertext :=
      "522dc1f099567d07f47f37a32a84427d643a8cdcbfe5c0c97598a2bd2555d1aa8cb08e48590dbb3da7b08b1056828838c5f61e6393ba7a0abcc9f662898015ad" }
]

def nistVectorSealTest : IO Unit :=
  vectors.forM fun v => do
    let key := hexToBytes v.key
    let nonce := hexToBytes v.iv
    let plaintext := hexToBytes v.plaintext
    let expected := hexToBytes (v.ciphertext ++ v.tag)
    check s!"seal matches NIST vector (key={v.key.take 8}...)" ((aes256GcmSeal key nonce plaintext) == expected)

def nistVectorOpenTest : IO Unit :=
  vectors.forM fun v => do
    let key := hexToBytes v.key
    let nonce := hexToBytes v.iv
    let sealed := hexToBytes (v.ciphertext ++ v.tag)
    let expected := hexToBytes v.plaintext
    check s!"open recovers the plaintext (key={v.key.take 8}...)" ((aes256GcmOpen key nonce sealed) == some expected)

/-- Round-trip holds for any key/nonce/plaintext of the right shape. -/
def roundtripHolds (key nonce plaintext : ByteArray) : Bool :=
  aes256GcmOpen key nonce (aes256GcmSeal key nonce plaintext) == some plaintext

def roundtripTest : IO Unit := do
  for _ in [0:20] do
    let key ← IO.getRandomBytes 32
    let nonce ← IO.getRandomBytes 12
    let len ← IO.rand 0 200
    let plaintext ← IO.getRandomBytes len.toUSize
    check "roundtrip holds for a random key/nonce/plaintext" (roundtripHolds key nonce plaintext)

def tamperedCiphertextRejectedTest : IO Unit := do
  let key ← IO.getRandomBytes 32
  let nonce ← IO.getRandomBytes 12
  let sealed := aes256GcmSeal key nonce (String.toUTF8 "hello, session")
  let tampered := ByteArray.mk (sealed.toList.set 0 (sealed.get! 0 ^^^ 0xFF)).toArray
  check "flipping a ciphertext byte breaks authentication" ((aes256GcmOpen key nonce tampered) == none)

def tamperedTagRejectedTest : IO Unit := do
  let key ← IO.getRandomBytes 32
  let nonce ← IO.getRandomBytes 12
  let sealed := aes256GcmSeal key nonce (String.toUTF8 "hello, session")
  let lastIdx := sealed.size - 1
  let tampered := ByteArray.mk (sealed.toList.set lastIdx (sealed.get! lastIdx ^^^ 0xFF)).toArray
  check "flipping a tag byte breaks authentication" ((aes256GcmOpen key nonce tampered) == none)

def wrongKeyRejectedTest : IO Unit := do
  let key ← IO.getRandomBytes 32
  let wrongKey ← IO.getRandomBytes 32
  let nonce ← IO.getRandomBytes 12
  let sealed := aes256GcmSeal key nonce (String.toUTF8 "hello, session")
  check "the wrong key fails to open" ((aes256GcmOpen wrongKey nonce sealed) == none)

def wrongNonceRejectedTest : IO Unit := do
  let key ← IO.getRandomBytes 32
  let nonce ← IO.getRandomBytes 12
  let wrongNonce ← IO.getRandomBytes 12
  let sealed := aes256GcmSeal key nonce (String.toUTF8 "hello, session")
  check "the wrong nonce fails to open" ((aes256GcmOpen key wrongNonce sealed) == none)

def emptyPlaintextRoundtripTest : IO Unit := do
  let key ← IO.getRandomBytes 32
  let nonce ← IO.getRandomBytes 12
  check "an empty plaintext round-trips" (roundtripHolds key nonce ByteArray.empty)

def run : IO Unit :=
  runGroup "Middleware.Crypto.AesGcm" do
    nistVectorSealTest
    nistVectorOpenTest
    roundtripTest
    tamperedCiphertextRejectedTest
    tamperedTagRejectedTest
    wrongKeyRejectedTest
    wrongNonceRejectedTest
    emptyPlaintextRoundtripTest

end Tests.Crypto.AesGcm
