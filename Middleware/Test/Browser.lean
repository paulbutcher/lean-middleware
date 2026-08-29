/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import Middleware.AntiForgery
public import Std.Http.Test.Helpers

public section

open Std.Http
open Std.Http.Server
open Std.Http.Internal.Test

namespace Middleware.Test

/-- Where `Browser.post` puts the token it holds. -/
inductive TokenPlacement where
  /-- A form field named after the stack's `AntiForgeryOptions.paramName`. -/
  | field
  /-- The `X-CSRF-Token` request header, which is what an application whose pages carry the
  token in a request header rather than in the form sends. -/
  | header
  /-- Nowhere: for a stack with no `antiForgery` in it, which has no token to hold and would
  otherwise be unpostable. Saying so is the caller's, since nothing about a response
  distinguishes a stack that mints no token from a page that forgot to render one. -/
  | omitted

/-- What follows the first occurrence of `marker`. -/
@[expose] def afterMarker (marker : List Char) : List Char → Option (List Char)
  | [] => if marker.isEmpty then some [] else none
  | c :: cs =>
    if marker.isPrefixOf (c :: cs) then some ((c :: cs).drop marker.length)
    else afterMarker marker cs

/-- What precedes the first occurrence of `terminator`, or `none` if there isn't one. -/
@[expose] def upTo (terminator : List Char) : List Char → Option (List Char)
  | [] => if terminator.isEmpty then some [] else none
  | c :: cs =>
    if terminator.isPrefixOf (c :: cs) then some []
    else (upTo terminator cs).map (c :: ·)

/-- The text between the first occurrence of `marker` and the next `terminator`. `none` if
`marker` doesn't occur, or if no `terminator` follows it.

What opens and what closes the token are both the caller's, because they differ: a hidden field
quotes it with `"`, an HTML attribute carrying it quotes it with an escaped `&quot;`. -/
@[expose] def tokenBetween (marker terminator body : String) : Option String :=
  ((afterMarker marker.toList body.toList).bind (upTo terminator.toList)).map String.ofList

/-- The `"`-quoted string following `marker`, which is the shape a hidden form field has.

Not the shape of a token carried inside an HTML *attribute*: an attribute's value is escaped, so
a quote within it is written `&quot;`, and this runs straight past it to the attribute's own
closing quote. That returns a token that is wrong rather than absent, which the application then
refuses with nothing about the refusal pointing back here. Scrape one of those with
`tokenBetween marker "&quot;"`; the standard HTMX idiom, `hx-headers` carrying
`{"X-CSRF-Token": "..."}`, wants `tokenBetween "X-CSRF-Token&quot;: &quot;" "&quot;"`. -/
@[expose] def tokenAfter (marker : String) (body : String) : Option String :=
  tokenBetween marker "\"" body

/--
A cookie jar and a held anti-forgery token, driving a middleware stack the way a browser drives
one: a page is fetched, its `Set-Cookie`s and its token are remembered, and the next request
carries them.

The jar alone is what any multi-request test needs, whatever the stack: a session read back on
a second request, a flash message set on one and shown on the next, a login that has to still be
in force three requests later.

The token is what a stack containing `antiForgery` additionally needs. Without it a test either
assembles both by hand, or drops down to a stack with neither, which passes whether or not the
page renders a token at all and whether or not the form would work in a browser.
-/
structure Browser where
  handler : TestHandler
  /-- Must match the `AntiForgeryOptions.paramName` of the `antiForgery` in `handler`. -/
  paramName : String
  tokenFrom : String → Option String
  /-- Name to raw wire value, as a browser stores them, so they go back out verbatim. -/
  cookies : IO.Ref (List (String × String))
  token : IO.Ref (Option String)

/--
`paramName` is a constructor argument rather than a field default so that `tokenFrom`'s default
can be written in terms of it.

An application whose pages carry the token somewhere other than a hidden field passes its own
`tokenFrom`; `tokenAfter` and `tokenBetween` are exported so that doing so is one line rather
than a scraper.

Reading the token from the session store instead of from the page would be steadier and would
defeat the point: a page that stopped rendering its token would still pass every test built on
this.
-/
def Browser.new (handler : TestHandler)
    (paramName : String := ({} : AntiForgeryOptions).paramName)
    (tokenFrom : String → Option String := tokenAfter s!"name=\"{paramName}\" value=\"") :
    IO Browser :=
  return { handler, paramName, tokenFrom, cookies := ← IO.mkRef [], token := ← IO.mkRef none }

private def headerBodyBoundary : ByteArray := "\x0d\n\x0d\n".toUTF8

private def splitResponse (response : ByteArray) : Option (List String × ByteArray) := do
  let at_ ← (Multipart.findAllOccurrences response headerBodyBoundary).toList.head?
  let headers ← String.fromUTF8? (response.extract 0 at_)
  pure (headers.splitOn "\x0d\n", response.extract (at_ + headerBodyBoundary.size) response.size)

private def setCookieValue (line : String) : Option String :=
  let marker := "set-cookie:"
  if line.toLower.startsWith marker then some (line.drop marker.length).trimAscii.toString
  else none

/-- Applies one `Set-Cookie` to the jar, replacing by name. A `Max-Age` of zero or less removes
the name instead. An `Expires` in the past is not interpreted: nothing in this library issues
one, and reading it would mean a clock this has no business depending on. -/
private def applySetCookie (jar : List (String × String)) (raw : String) :
    List (String × String) :=
  match raw.splitOn ";" with
  | [] => jar
  | pair :: attrs =>
    match pair.splitOn "=" with
    | [] | [_] => jar
    | name :: rest =>
      let name := name.trimAscii.toString
      let value := (String.intercalate "=" rest).trimAscii.toString
      let expired := attrs.any fun attr =>
        match attr.splitOn "=" with
        | key :: v :: _ =>
          key.trimAscii.toString.toLower == "max-age" &&
            (v.trimAscii.toString.toInt?.any (· ≤ (0 : Int)))
        | _ => false
      let jar := jar.filter (·.fst != name)
      if expired then jar else jar ++ [(name, value)]

private def Browser.harvest (browser : Browser) (response : ByteArray) : IO Unit := do
  let some (headers, body) := splitResponse response
    | throw <| IO.userError "response carries no header/body boundary"
  browser.cookies.modify fun jar =>
    (headers.filterMap setCookieValue).foldl applySetCookie jar
  -- A response yielding no token leaves the held one alone: a fragment legitimately carries
  -- none, and clearing on every partial response would make the next post fail for a reason
  -- that is not about the application.
  match String.fromUTF8? body |>.bind browser.tokenFrom with
  | some token => browser.token.set (some token)
  | none => pure ()

/-- Runs one request on a fresh mock connection, as a browser does. Built on `check` rather than
`Mock.new` and `serveConnection` so that a failure still reports under a name. -/
private def Browser.run (browser : Browser) (name raw : String) : IO ByteArray := do
  let captured ← IO.mkRef ByteArray.empty
  check name raw browser.handler fun response => do
    browser.harvest response
    captured.set response
  captured.get

private def Browser.cookieHeader (browser : Browser) : IO String := do
  match ← browser.cookies.get with
  | [] => pure ""
  | jar =>
    let pairs := String.intercalate "; " (jar.map fun (name, value) => s!"{name}={value}")
    pure s!"Cookie: {pairs}\x0d\n"

/-- Percent-encodes a form field name or value. Deliberately not
`URI.EncodedQueryParam.encode`, whose `+`-for-space convention leaves a literal `+` in a value
indistinguishable from a space by the time the stack decodes it. -/
private def formEncode (s : String) : String :=
  toString (URI.EncodedString.encode (r := Std.Http.Internal.Char.isQueryDataChar) s)
    |>.replace "+" "%2B"

private def Browser.heldToken (browser : Browser) (path : String) : IO String := do
  let some token ← browser.token.get
    | throw <| IO.userError s!"no anti-forgery token held, so POST {path} is not a request a \
        browser could make: fetch a page that renders one first, or pass `.omitted` if this \
        stack has no `antiForgery` in it"
  pure token

/-- Fetches `path`, sending the jar's cookies and harvesting whatever the response sets, along
with a token if the body carries one. Returns the raw response, so `assertStatus` and the rest
apply to it unchanged. -/
def Browser.get (browser : Browser) (path : String) (extra : String := "") : IO ByteArray := do
  let headers := (← browser.cookieHeader) ++ "Connection: close\x0d\n" ++ extra
  browser.run s!"GET {path}" (mkGet path headers)

/--
Posts `fields` as `application/x-www-form-urlencoded`, with the jar's cookies and the held token.

Under `.field` or `.header`, throws when no token is held, naming `path`. A post with no token
in hand is not something a browser can do against a stack that demands one, and answering it
with a `403` that a test reads as a pass is the exact failure this exists to remove; a test that
wants to check that refusal builds the request with `mkPost`. `.omitted` is how a stack with no
`antiForgery` in it posts.
-/
def Browser.post (browser : Browser) (path : String) (fields : List (String × String))
    (placement : TokenPlacement := .field) (extra : String := "") : IO ByteArray := do
  let (fields, tokenHeader) ← match placement with
    | .field => do
      let token ← browser.heldToken path
      pure (fields ++ [(browser.paramName, token)], "")
    | .header => do
      let token ← browser.heldToken path
      pure (fields, s!"{Header.Name.xCsrfToken}: {token}\x0d\n")
    | .omitted => pure (fields, "")
  let body := String.intercalate "&" (fields.map fun (name, value) =>
    s!"{formEncode name}={formEncode value}")
  let headers := (← browser.cookieHeader)
    ++ "Content-Type: application/x-www-form-urlencoded\x0d\n" ++ tokenHeader
    ++ "Connection: close\x0d\n" ++ extra
  browser.run s!"POST {path}" (mkPost path body headers)

/-- The raw wire value the jar holds for `name`, as it would go back out in a `Cookie` header. -/
def Browser.cookie? (browser : Browser) (name : String) : IO (Option String) := do
  pure (((← browser.cookies.get).find? (·.fst == name)).map Prod.snd)

def Browser.token? (browser : Browser) : IO (Option String) :=
  browser.token.get

end Middleware.Test
