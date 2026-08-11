/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Middleware.Crypto.Base64
import Std.Http.Test.Helpers
import Plausible

open Middleware.Crypto
open Std.Http.Internal.Test (runGroup)

namespace Tests.Crypto.Base64

private def check (name : String) (cond : Bool) : IO Unit :=
  unless cond do throw <| IO.userError s!"{name} failed"

/-- RFC 4648 §10's own worked examples, verbatim. -/
def rfcVectorEncodeTest : IO Unit := do
  check "" (Base64.encode (String.toUTF8 "") == "")
  check "f" (Base64.encode (String.toUTF8 "f") == "Zg==")
  check "fo" (Base64.encode (String.toUTF8 "fo") == "Zm8=")
  check "foo" (Base64.encode (String.toUTF8 "foo") == "Zm9v")
  check "foob" (Base64.encode (String.toUTF8 "foob") == "Zm9vYg==")
  check "fooba" (Base64.encode (String.toUTF8 "fooba") == "Zm9vYmE=")
  check "foobar" (Base64.encode (String.toUTF8 "foobar") == "Zm9vYmFy")

def rfcVectorDecodeTest : IO Unit := do
  check "" (Base64.decode "" == some (String.toUTF8 ""))
  check "f" (Base64.decode "Zg==" == some (String.toUTF8 "f"))
  check "fo" (Base64.decode "Zm8=" == some (String.toUTF8 "fo"))
  check "foo" (Base64.decode "Zm9v" == some (String.toUTF8 "foo"))
  check "foob" (Base64.decode "Zm9vYg==" == some (String.toUTF8 "foob"))
  check "fooba" (Base64.decode "Zm9vYmE=" == some (String.toUTF8 "fooba"))
  check "foobar" (Base64.decode "Zm9vYmFy" == some (String.toUTF8 "foobar"))

def malformedInputRejectedTest : IO Unit := do
  check "wrong length (not a multiple of 4)" (Base64.decode "Zm9" == none)
  check "a character outside the alphabet" (Base64.decode "Zm9$" == none)
  check "padding in a non-final position" (Base64.decode "Z=g=Zm9v" == none)
  check "too much padding" (Base64.decode "Z===" == none)

/-- Decoding what `encode` produces always recovers the original bytes. -/
def roundtripHolds (data : ByteArray) : Bool :=
  Base64.decode (Base64.encode data) == some data

def roundtripTest : IO Unit := do
  match ← Plausible.Testable.checkIO (Plausible.NamedBinder "data" <| ∀ data : List UInt8,
      roundtripHolds (ByteArray.mk data.toArray) = true) with
  | .success _ => pure ()
  | .gaveUp n => throw <| IO.userError s!"gave up after {n} tries"
  | .failure _ steps _ => throw <| IO.userError s!"counter-example found: {steps}"

def run : IO Unit :=
  runGroup "Middleware.Crypto.Base64" do
    rfcVectorEncodeTest
    rfcVectorDecodeTest
    malformedInputRejectedTest
    roundtripTest

end Tests.Crypto.Base64
