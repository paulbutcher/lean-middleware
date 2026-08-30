/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public section

namespace Middleware.Crypto.Base64

private def alphabet : Array Char :=
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".toList.toArray

private def encodeChar (v : UInt8) : Char := alphabet[v.toNat]!

private def decodeChar (c : Char) : Option UInt8 :=
  if 'A' ≤ c ∧ c ≤ 'Z' then some (c.toNat - 'A'.toNat).toUInt8
  else if 'a' ≤ c ∧ c ≤ 'z' then some ((c.toNat - 'a'.toNat) + 26).toUInt8
  else if '0' ≤ c ∧ c ≤ '9' then some ((c.toNat - '0'.toNat) + 52).toUInt8
  else if c == '+' then some 62
  else if c == '/' then some 63
  else none

private def encodeTriple (b0 b1 b2 : UInt8) : List Char :=
  let triple := (b0.toUInt32 <<< 16) ||| (b1.toUInt32 <<< 8) ||| b2.toUInt32
  [encodeChar ((triple >>> 18) &&& 0x3f).toUInt8,
   encodeChar ((triple >>> 12) &&& 0x3f).toUInt8,
   encodeChar ((triple >>> 6) &&& 0x3f).toUInt8,
   encodeChar (triple &&& 0x3f).toUInt8]

private def encodeGo : List UInt8 → List Char
  | b0 :: b1 :: b2 :: rest => encodeTriple b0 b1 b2 ++ encodeGo rest
  | [b0, b1] =>
    let triple := (b0.toUInt32 <<< 16) ||| (b1.toUInt32 <<< 8)
    [encodeChar ((triple >>> 18) &&& 0x3f).toUInt8,
     encodeChar ((triple >>> 12) &&& 0x3f).toUInt8,
     encodeChar ((triple >>> 6) &&& 0x3f).toUInt8, '=']
  | [b0] =>
    let triple := b0.toUInt32 <<< 16
    [encodeChar ((triple >>> 18) &&& 0x3f).toUInt8,
     encodeChar ((triple >>> 12) &&& 0x3f).toUInt8, '=', '=']
  | [] => []

/-- RFC 4648 standard (not URL-safe) base64 encoding. -/
def encode (data : ByteArray) : String :=
  String.ofList (encodeGo data.toList)

private def decodeQuad (c0 c1 c2 c3 : Char) : Option (List UInt8) := do
  let v0 ← decodeChar c0
  let v1 ← decodeChar c1
  if c2 == '=' then
    if c3 != '=' then none
    else
      let triple := (v0.toUInt32 <<< 18) ||| (v1.toUInt32 <<< 12)
      some [(triple >>> 16).toUInt8]
  else if c3 == '=' then
    let v2 ← decodeChar c2
    let triple := (v0.toUInt32 <<< 18) ||| (v1.toUInt32 <<< 12) ||| (v2.toUInt32 <<< 6)
    some [(triple >>> 16).toUInt8, (triple >>> 8).toUInt8]
  else
    let v2 ← decodeChar c2
    let v3 ← decodeChar c3
    let triple := (v0.toUInt32 <<< 18) ||| (v1.toUInt32 <<< 12) ||| (v2.toUInt32 <<< 6) ||| v3.toUInt32
    some [(triple >>> 16).toUInt8, (triple >>> 8).toUInt8, triple.toUInt8]

/-- `=` padding is only valid on the final 4-character group of a base64 string, and only as its
last one or two characters; rejected (`none`) anywhere else, rather than silently accepted. -/
private def decodeGo : List Char → Option (List UInt8)
  | [] => some []
  | c0 :: c1 :: c2 :: c3 :: rest =>
    if rest.isEmpty then
      decodeQuad c0 c1 c2 c3
    else if c0 == '=' ∨ c1 == '=' ∨ c2 == '=' ∨ c3 == '=' then
      none
    else do
      let bytes ← decodeQuad c0 c1 c2 c3
      let restBytes ← decodeGo rest
      some (bytes ++ restBytes)
  | _ => none

/-- Decodes a standard base64 string. `none` if it isn't validly formed: a length that isn't a
multiple of 4, a character outside the base64 alphabet, or `=` padding anywhere but the end. -/
def decode (s : String) : Option ByteArray :=
  (decodeGo s.toList).map (ByteArray.mk ∘ List.toArray)

end Middleware.Crypto.Base64
