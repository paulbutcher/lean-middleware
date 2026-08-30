/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import Middleware.Test.Browser

public section

open Std.Http
open Std.Http.Server
open Std.Http.Internal.Test
open Middleware (cookies session params MemoryStore antiForgery AntiForgeryToken
  AntiForgeryOptions Params SessionData SessionUpdate SetCookie SetCookies Session)
open Middleware.Test (Browser tokenAfter tokenBetween afterMarker upTo)

namespace Tests.Browser

/-- The field name the stack under test and `Browser`'s default `tokenFrom` have to agree on;
taking it from the same place both do is what makes them agree. -/
def tokenField : String := ({} : AntiForgeryOptions).paramName

def appHandler : StatelessHandler :=
  { onRequest := fun req => do
      if req.line.method == .post then
        let title := ((req.extensions.get Params).bind (·.get "title")).getD "<none>"
        Response.ok |>.text s!"posted:{title}"
      else
        let token := ((req.extensions.get AntiForgeryToken).map (·.value)).getD ""
        Response.ok |>.html
          s!"<form method=\"post\" action=\"/submit\"><input type=\"hidden\" \
             name=\"{tokenField}\" value=\"{token}\"></form>" }

def app (store : MemoryStore) : StatelessHandler :=
  Middleware.apply [cookies, session store {}, params, antiForgery {}] appHandler

def formRoundTripTest : IO Unit :=
  runGroup "a form round trip reaches the inner handler" do
    let store ← MemoryStore.new
    let browser ← Browser.new (app store).onRequest
    let page ← browser.get "/"
    assertStatus page "HTTP/1.1 200"
    let response ← browser.post "/submit" [("title", "hello")]
    assertStatus response "HTTP/1.1 200"
    assertContains response "posted:hello"

def handBuiltPostRefusedTest : IO Unit := do
  let store ← MemoryStore.new
  check "the same POST built by hand, carrying neither jar nor token, is refused"
    (mkPost "/submit" "title=hello"
      "Content-Type: application/x-www-form-urlencoded\x0d\nConnection: close\x0d\n")
    (app store).onRequest fun response => assertStatus response "HTTP/1.1 403"

def headerPlacementTest : IO Unit :=
  runGroup "the same round trip with the token in X-CSRF-Token" do
    let store ← MemoryStore.new
    let browser ← Browser.new (app store).onRequest
    let _ ← browser.get "/"
    let response ← browser.post "/submit" [("title", "hello")] .header
    assertContains response "posted:hello"

def encodedFieldValueTest : IO Unit :=
  runGroup "a field value needing encoding arrives at the handler intact" do
    let store ← MemoryStore.new
    let browser ← Browser.new (app store).onRequest
    let _ ← browser.get "/"
    let response ← browser.post "/submit" [("title", "a+b & c=d")]
    assertContains response "posted:a+b & c=d"

/-- Carries the token the way an HTMX application does, in an `hx-headers` attribute, where it
is quoted with an escaped `&quot;` rather than a raw `"`. -/
def hxHeadersHandler : StatelessHandler :=
  { onRequest := fun req => do
      if req.line.method == .post then
        let title := ((req.extensions.get Params).bind (·.get "title")).getD "<none>"
        Response.ok |>.text s!"posted:{title}"
      else
        let token := ((req.extensions.get AntiForgeryToken).map (·.value)).getD ""
        Response.ok |>.html
          ("<body hx-headers=\"{&quot;X-CSRF-Token&quot;: &quot;" ++ token
            ++ "&quot;}\"></body>") }

def escapedAttributeTokenTest : IO Unit :=
  runGroup "a token quoted inside an escaped attribute is scraped whole" do
    let store ← MemoryStore.new
    let browser ← Browser.new
      (Middleware.apply [cookies, session store {}, params, antiForgery {}]
        hxHeadersHandler).onRequest
      (tokenFrom := tokenBetween "X-CSRF-Token&quot;: &quot;" "&quot;")
    let _ ← browser.get "/"
    let response ← browser.post "/submit" [("title", "hello")] .header
    assertContains response "posted:hello"

private def postError (browser : Browser) : IO (Option String) := do
  try
    let _ ← browser.post "/submit" []
    pure none
  catch e => pure (some (toString e))

def postWithoutTokenThrowsTest : IO Unit :=
  runGroup "a POST with no token held throws, naming which mistake left it with none" do
    let store ← MemoryStore.new
    let unfetched ← Browser.new (app store).onRequest
    match ← postError unfetched with
    | none => throw <| IO.userError "expected a POST with no token held to throw"
    | some message =>
      unless message.contains "nothing has been fetched" do
        throw <| IO.userError s!"expected the message to blame the missing fetch: {message}"
    -- The default `tokenFrom` against a page that quotes its token with `&quot;`: fetched, and
    -- unreadable where it looked, which is the other mistake entirely.
    let unreadable ← Browser.new
      (Middleware.apply [cookies, session store {}, params, antiForgery {}]
        hxHeadersHandler).onRequest
    let _ ← unreadable.get "/"
    match ← postError unreadable with
    | none => throw <| IO.userError "expected a POST with an unreadable token to throw"
    | some message =>
      unless message.contains "tokenBetween" do
        throw <| IO.userError s!"expected the message to blame `tokenFrom`: {message}"

def postWithoutAntiForgeryTest : IO Unit :=
  runGroup "a stack with no antiForgery is posted to with .omitted, no page fetched first" do
    let store ← MemoryStore.new
    let browser ← Browser.new
      (Middleware.apply [cookies, session store {}, params] appHandler).onRequest
    let response ← browser.post "/submit" [("title", "hello")] .omitted
    assertContains response "posted:hello"

def visitHandler : StatelessHandler :=
  { onRequest := fun req => do
      let data := ((req.extensions.get SessionData).getD {}).data
      match data.get "visited" with
      | some v => Response.ok |>.text s!"visited:{v}"
      | none =>
        Response.ok
          |>.extension (SessionUpdate.write (data.set "visited" "yes"))
          |>.text "visited:none" }

def sessionCarriedByJarTest : IO Unit :=
  runGroup "the jar carries the session cookie from one request to the next" do
    let store ← MemoryStore.new
    let browser ← Browser.new
      (Middleware.apply [cookies, session store {}] visitHandler).onRequest
    assertContains (← browser.get "/") "visited:none"
    assertContains (← browser.get "/") "visited:yes"

def flavourHandler : StatelessHandler :=
  { onRequest := fun req =>
      let cookie : SetCookie :=
        if toString req.line.uri.path == "/clear" then
          { name := "flavour", value := "", attrs := { maxAge := some 0 } }
        else
          { name := "flavour", value := "vanilla" }
      Response.ok |>.extension ({ cookies := [cookie] } : SetCookies) |>.text "ok" }

def maxAgeZeroClearsJarTest : IO Unit :=
  runGroup "a Set-Cookie with Max-Age=0 clears the jar entry" do
    let browser ← Browser.new (cookies flavourHandler).onRequest
    let _ ← browser.get "/set"
    unless (← browser.cookie? "flavour") == some "vanilla" do
      throw <| IO.userError "expected the jar to hold the cookie the response set"
    let _ ← browser.get "/clear"
    unless (← browser.cookie? "flavour") == none do
      throw <| IO.userError "expected Max-Age=0 to have removed the jar entry"

/--
The base case of the scraper's first half: given text that begins with the marker, `afterMarker`
hands back precisely the remainder. Everything the token theorems say about a real page reduces
to this once `afterMarker_of_no_earlier_match` has walked the page's leading text away.

For any `marker` and any `rest`, `afterMarker marker (marker ++ rest)` is `some rest`. The empty
marker is included rather than excluded: the `[]` case of `afterMarker` answers `some []` for it,
which is the same `rest`, so the statement holds uniformly and needs no side condition.
-/
private theorem afterMarker_append (marker rest : List Char) :
    afterMarker marker (marker ++ rest) = some rest := by
  cases marker with
  | nil => cases rest <;> simp [afterMarker]
  | cons m ms => simp [afterMarker, List.isPrefixOf]

/--
The base case of the scraper's second half: given a value followed by its terminator, `upTo`
stops at that terminator and returns exactly the value. This is what rules out an overrun, a
token read past its closing delimiter and on into the rest of the page.

For any `terminator`, `value` and `rest`, if no non-empty suffix `s` of `value` begins an
occurrence of `terminator` when read together with what follows it (`h`), then
`upTo terminator (value ++ (terminator ++ rest))` is `some value`. The hypothesis `h` is what
forbids the terminator appearing inside the value, including the case where it straddles the
value's tail and the terminator's own first characters, which is why it is stated over
`s ++ (terminator ++ rest)` rather than over `value` alone.
-/
private theorem upTo_append (terminator value rest : List Char)
    (h : ∀ s, s <:+ value → s ≠ [] → ¬ terminator <+: (s ++ (terminator ++ rest))) :
    upTo terminator (value ++ (terminator ++ rest)) = some value := by
  induction value with
  | nil => cases terminator <;> cases rest <;> simp [upTo, List.isPrefixOf]
  | cons c cs ih =>
    have hno : ¬ terminator <+: c :: (cs ++ (terminator ++ rest)) := by
      simpa using h (c :: cs) (List.suffix_refl _) (by simp)
    rw [List.cons_append]
    simp only [upTo, List.isPrefixOf_iff_prefix, hno, if_false]
    rw [ih fun s hs hne => h s (hs.trans (List.suffix_cons c cs)) hne]
    simp

/--
The single-character terminator specialises `upTo_append` to a hypothesis a caller can actually
check by eye: for a one-character terminator, "no occurrence straddles anything" is just "the
character does not appear in the value". This is the form `tokenAfter_of_rendered` uses, where
the terminator is the `"` closing a hidden form field.

For any character `t`, `value` and `rest`, if `t` is not a member of `value`, then
`upTo [t] (value ++ (t :: rest))` is `some value`. A one-character terminator cannot straddle a
boundary, so simple non-membership is genuinely enough here where the general case needs the
suffix-based hypothesis.
-/
private theorem upTo_singleton (t : Char) (value rest : List Char) (h : t ∉ value) :
    upTo [t] (value ++ (t :: rest)) = some value := by
  induction value with
  | nil => simp [upTo, List.isPrefixOf]
  | cons c cs ih => simp_all [upTo, List.isPrefixOf, Ne.symm]

/--
Leading page content that does not itself start the marker is skipped without effect: the scraper
finds the same thing it would have found in the text alone. This is what makes the token theorems
statements about a real page, where the marker is preceded by an arbitrary amount of unrelated
HTML, rather than only about text that begins at the marker.

For any `marker`, `pre` and `rest`, if no non-empty suffix `s` of `pre` begins an occurrence of
`marker` when read together with `rest` (`h`), then `afterMarker marker (pre ++ rest)` equals
`afterMarker marker rest`. The hypothesis is stated over `s ++ rest` rather than over `pre`
because a marker can begin in `pre` and finish in `rest`; that straddling case is exactly what an
"the marker does not occur in `pre`" hypothesis would miss.
-/
private theorem afterMarker_of_no_earlier_match (marker pre rest : List Char)
    (h : ∀ s, s <:+ pre → s ≠ [] → ¬ marker <+: (s ++ rest)) :
    afterMarker marker (pre ++ rest) = afterMarker marker rest := by
  induction pre with
  | nil => simp
  | cons c cs ih =>
    have hne : ¬ marker <+: c :: (cs ++ rest) := by
      simpa using h (c :: cs) (List.suffix_refl _) (by simp)
    rw [List.cons_append]
    simp only [afterMarker, List.isPrefixOf_iff_prefix, hne, if_false]
    exact ih fun s hs hne' => h s (hs.trans (List.suffix_cons c cs)) hne'

/--
`tokenBetween` reads back exactly what was rendered, so a `Browser` posts the token the page
really carries rather than a truncated or overrun reading of it. A token misread here becomes a
post the application refuses, with nothing about the refusal pointing back at the scraper, which
is the failure this is worth proving away.

For strings `marker`, `terminator`, `pre`, `value` and `rest`: on the page
`pre ++ marker ++ value ++ terminator ++ rest`, if nothing in `pre` starts an earlier occurrence
of the marker (`hearlier`) and the terminator does not occur within the value (`hvalue`), then
`tokenBetween marker terminator` of that page is `some value`, and nothing else. The two
hypotheses are the two ways a page could defeat the scraper, an earlier marker and an early
terminator; both are stated over suffixes read together with the following text, so each also
covers the case of a match straddling the boundary between the two pieces.
-/
theorem tokenBetween_of_rendered (marker terminator pre value rest : String)
    (hearlier : ∀ s, s <:+ pre.toList → s ≠ [] →
      ¬ marker.toList <+: (s ++ (marker ++ value ++ terminator ++ rest).toList))
    (hvalue : ∀ s, s <:+ value.toList → s ≠ [] →
      ¬ terminator.toList <+: (s ++ (terminator.toList ++ rest.toList))) :
    tokenBetween marker terminator (pre ++ (marker ++ value ++ terminator ++ rest))
      = some value := by
  have hafter : afterMarker marker.toList (pre ++ (marker ++ value ++ terminator ++ rest)).toList
      = some (value.toList ++ (terminator.toList ++ rest.toList)) := by
    rw [String.toList_append, afterMarker_of_no_earlier_match _ _ _ hearlier]
    simpa [String.toList_append, List.append_assoc] using
      afterMarker_append marker.toList (value.toList ++ (terminator.toList ++ rest.toList))
  simp only [tokenBetween, hafter, Option.bind_some,
    upTo_append terminator.toList value.toList rest.toList hvalue,
    Option.map_some, String.ofList_toList]

/--
The hidden-field case, which is the default a `Browser` uses when no `tokenFrom` is given: the
same guarantee as `tokenBetween_of_rendered` for a token closed by a plain `"`. Worth stating on
its own because it is the shape almost every page uses, and because its second hypothesis is one
a reader can check against the markup directly.

For strings `marker`, `pre`, `value` and `rest`: on the page `pre ++ marker ++ value ++ "\"" ++
rest`, if nothing in `pre` starts an earlier occurrence of the marker (`hearlier`) and the value
contains no `"` (`hquote`), then `tokenAfter marker` of that page is `some value`. The terminator
being a single character is what lets `hvalue`'s general suffix condition collapse to plain
non-membership here; a token rendered inside an HTML attribute is delimited by `&quot;` instead
and so falls outside this theorem, which is why `tokenBetween` exists.
-/
theorem tokenAfter_of_rendered (marker pre value rest : String)
    (hearlier : ∀ s, s <:+ pre.toList → s ≠ [] →
      ¬ marker.toList <+: (s ++ (marker ++ value ++ "\"" ++ rest).toList))
    (hquote : '"' ∉ value.toList) :
    tokenAfter marker (pre ++ (marker ++ value ++ "\"" ++ rest)) = some value := by
  have hquoteList : "\"".toList = ['"'] := rfl
  have hafter : afterMarker marker.toList (pre ++ (marker ++ value ++ "\"" ++ rest)).toList
      = some (value.toList ++ ('"' :: rest.toList)) := by
    rw [String.toList_append, afterMarker_of_no_earlier_match _ _ _ hearlier]
    simpa [String.toList_append, List.append_assoc] using
      afterMarker_append marker.toList (value.toList ++ ('"' :: rest.toList))
  simp only [tokenAfter, tokenBetween, hafter, hquoteList, Option.bind_some,
    upTo_singleton '"' value.toList rest.toList hquote, Option.map_some, String.ofList_toList]

def run : IO Unit :=
  runGroup "Middleware.Test.Browser" do
    formRoundTripTest
    handBuiltPostRefusedTest
    headerPlacementTest
    escapedAttributeTokenTest
    encodedFieldValueTest
    postWithoutTokenThrowsTest
    postWithoutAntiForgeryTest
    sessionCarriedByJarTest
    maxAgeZeroClearsJarTest

end Tests.Browser
