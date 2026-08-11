/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Middleware.Core
import Std.Time

open Std.Http
open Std.Http.Server

namespace Middleware.Header.Name

def cookie : Header.Name := .mk "cookie"
def setCookie : Header.Name := .mk "set-cookie"

end Middleware.Header.Name

namespace Middleware

/-- `Set-Cookie`'s `SameSite` attribute. A post-RFC-6265 addition (RFC 6265bis / CHIPS); the
base RFC's `extension-av` grammar already accommodates it even though it doesn't name it. -/
inductive SameSite where
  | strict
  | lax
  | none
deriving BEq, Repr

namespace SameSite

def toWire : SameSite → String
  | .strict => "Strict"
  | .lax => "Lax"
  | .none => "None"

end SameSite

/-- `Set-Cookie` attributes beyond the bare `name=value` pair (RFC 6265 §4.1.1 `cookie-av`, plus
the `SameSite` extension). -/
structure CookieAttrs where
  domain : Option String := none
  path : Option String := none
  /-- Seconds. `0` or negative immediately expires the cookie client-side; real clients honor
  this even though RFC 6265's own `Max-Age` ABNF only spells out positive values. -/
  maxAge : Option Int := none
  expires : Option Std.Time.DateTime := none
  secure : Bool := false
  httpOnly : Bool := false
  sameSite : Option SameSite := none

/-- Percent-encodes a cookie value so it's always valid `cookie-octet`. Deliberately built on
`URI.EncodedString (r := isPChar)` (the same primitive `URI.EncodedSegment` -- path segments --
uses), not `URI.EncodedQueryParam`: the query encoding has a form-urlencoded-only convention of
representing a space as a bare `+`, which is ambiguous with (and so corrupts) a value that itself
legitimately contains a literal `+` -- a real bug caught by a `Plausible` round-trip test.
`isPChar` still leaves `;`, `,`, and `+` unescaped (all valid RFC 3986 `sub-delims`), so those
three are escaped here on top: `;`/`,` because `cookie-octet` excludes them outright, `+` because
`isPChar` has no such special meaning to worry about but escaping it keeps this independent of
that concern regardless. -/
def encodeCookieValue (value : String) : String :=
  toString (URI.EncodedString.encode (r := Std.Http.Internal.Char.isPChar) value)
    |>.replace ";" "%3B" |>.replace "," "%2C" |>.replace "+" "%2B"

/-- Decodes a cookie value produced by `encodeCookieValue`, or any other validly percent-encoded
wire value. -/
def decodeCookieValue (wire : String) : Option String :=
  (URI.EncodedString.ofString? (r := Std.Http.Internal.Char.isPChar) wire).bind (·.decode)

/-- A cookie to be sent to the client via `Set-Cookie`. -/
structure SetCookie where
  name : String
  value : String
  attrs : CookieAttrs := {}

namespace SetCookie

private def renderAttrs (attrs : CookieAttrs) : String :=
  let parts : List (Option String) :=
    [ attrs.domain.map (s!"; Domain={·}"),
      attrs.path.map (s!"; Path={·}"),
      attrs.maxAge.map (s!"; Max-Age={·}"),
      attrs.expires.map (fun d => s!"; Expires={d.toRFC822String}"),
      if attrs.secure then some "; Secure" else none,
      if attrs.httpOnly then some "; HttpOnly" else none,
      attrs.sameSite.map (s!"; SameSite={·.toWire}") ]
  String.join (parts.filterMap (·))

/-- Renders `name=value; Attr=val; ...`, percent-encoding `value` so it's always valid
`cookie-octet` regardless of what characters the application put in it. -/
def serialize (c : SetCookie) : Header.Name × Header.Value :=
  let raw := s!"{c.name}={encodeCookieValue c.value}{renderAttrs c.attrs}"
  (Middleware.Header.Name.setCookie, Header.Value.ofString! raw)

/-- Parses back the `name=value` pair a `Set-Cookie` header carries. Attributes are write-only
in practice (nothing re-parses a response's own `Set-Cookie` for its attributes), so they're
ignored here rather than round-tripped. -/
def parse (v : Header.Value) : Option SetCookie :=
  match v.value.splitOn ";" with
  | [] => none
  | pair :: _ =>
    match pair.splitOn "=" with
    | [] => none
    | [_] => none
    | name :: rest =>
      let name := name.trimAscii.toString
      let rawValue := (String.intercalate "=" rest).trimAscii.toString
      (decodeCookieValue rawValue).map ({ name, value := · })

instance : Header SetCookie := ⟨parse, serialize⟩

end SetCookie

/-- Cookies parsed from the request's `Cookie` header. -/
structure Cookies where
  pairs : List (String × String) := []
deriving TypeName

namespace Cookies

def get (c : Cookies) (name : String) : Option String :=
  (c.pairs.find? (·.fst == name)).map Prod.snd

end Cookies

/-- Cookies to be sent back via `Set-Cookie`, accumulated on the response (typically via
`appendSetCookie`) and turned into headers by `cookies`. -/
structure SetCookies where
  cookies : List SetCookie := []
deriving TypeName

/-- Adds a cookie to a response's outgoing `Set-Cookie` list, preserving whatever's already
there. `Extensions.insert` replaces same-type values wholesale, so this reads the existing list
first rather than clobbering it -- lets `session`/`flash`/the application handler each
contribute a cookie without knowing about each other. -/
def appendSetCookie (resp : Response Body.Any) (c : SetCookie) : Response Body.Any :=
  let existing := (resp.extensions.get SetCookies).getD {}
  { resp with extensions := resp.extensions.insert ({ existing with
      cookies := existing.cookies ++ [c] } : SetCookies) }

/-- Splits a `Cookie` header (`name1=value1; name2=value2`, RFC 6265 §4.2.1 -- no attributes,
those are `Set-Cookie`-only) into decoded pairs. A pair whose value isn't validly
percent-encoded is dropped rather than failing the whole header: real `Cookie` headers routinely
carry stray entries from unrelated scripts, and RFC 6265 §5.3/6 anticipates lenient handling.
Quoted cookie-values (`DQUOTE *cookie-octet DQUOTE`) aren't handled -- no real browser sends one
for a cookie this library itself set, and that's the only case this needs to round-trip. -/
def parseCookieHeader (s : String) : List (String × String) :=
  (s.splitOn ";").filterMap fun part =>
    match part.trimAscii.toString.splitOn "=" with
    | [] => none
    | [_] => none
    | name :: rest =>
      let name := name.trimAscii.toString
      let rawValue := (String.intercalate "=" rest).trimAscii.toString
      (decodeCookieValue rawValue).map (name, ·)

/-- Attaches a `Cookies` extension parsed from the request's `Cookie` header, and converts any
`SetCookies` accumulated on the response (see `appendSetCookie`) into `Set-Cookie` headers --
one header line per cookie (never comma-folded: RFC 6265 forbids it, since `Expires` values
themselves contain commas). -/
def cookies : Middleware :=
  fun handler =>
    { handler with
      onRequest := fun req => do
        let pairs :=
          match req.line.headers.get? Header.Name.cookie with
          | none => []
          | some v => parseCookieHeader v.value
        let req := { req with extensions := req.extensions.insert ({ pairs } : Cookies) }
        let resp ← handler.onRequest req
        match resp.extensions.get SetCookies with
        | none => pure resp
        | some sc =>
          let headers := sc.cookies.foldl (init := resp.line.headers) fun hs c =>
            let (name, value) := SetCookie.serialize c
            hs.insert name value
          pure { resp with line := { resp.line with headers } } }

end Middleware
