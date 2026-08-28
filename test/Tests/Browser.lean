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
open Middleware.Test (Browser tokenAfter afterMarker upToQuote)

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

def postWithoutTokenThrowsTest : IO Unit :=
  runGroup "a POST with no token held throws rather than returning a 403" do
    let store ← MemoryStore.new
    let browser ← Browser.new (app store).onRequest
    let threw ← try
        let _ ← browser.post "/submit" []
        pure false
      catch _ => pure true
    unless threw do
      throw <| IO.userError "expected a POST with no token held to throw"

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

private theorem afterMarker_append (marker rest : List Char) :
    afterMarker marker (marker ++ rest) = some rest := by
  cases marker with
  | nil => cases rest <;> simp [afterMarker]
  | cons m ms => simp [afterMarker, List.isPrefixOf]

private theorem upToQuote_append (value rest : List Char) (h : '"' ∉ value) :
    upToQuote (value ++ '"' :: rest) = some value := by
  induction value with
  | nil => simp [upToQuote]
  | cons c cs ih => simp_all [upToQuote, Ne.symm]

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

/-- `tokenAfter` reads back exactly what was rendered: on a page whose first occurrence of
`marker` (`hearlier`: nothing before it starts one) is followed by a quote-free `value` and then
a closing quote, it yields `value` and nothing else, whatever else the page contains. A token
misread here becomes a post the application refuses, with nothing about the refusal pointing
back at the scraper. -/
theorem tokenAfter_of_rendered (marker pre value rest : String)
    (hearlier : ∀ s, s <:+ pre.toList → s ≠ [] →
      ¬ marker.toList <+: (s ++ (marker ++ value ++ "\"" ++ rest).toList))
    (hquote : '"' ∉ value.toList) :
    tokenAfter marker (pre ++ (marker ++ value ++ "\"" ++ rest)) = some value := by
  have hafter : afterMarker marker.toList (pre ++ (marker ++ value ++ "\"" ++ rest)).toList
      = some (value.toList ++ '"' :: rest.toList) := by
    rw [String.toList_append, afterMarker_of_no_earlier_match _ _ _ hearlier]
    simpa [String.toList_append, List.append_assoc] using
      afterMarker_append marker.toList (value.toList ++ '"' :: rest.toList)
  simp only [tokenAfter, hafter, Option.bind_some,
    upToQuote_append value.toList rest.toList hquote, Option.map_some, String.ofList_toList]

def run : IO Unit :=
  runGroup "Middleware.Test.Browser" do
    formRoundTripTest
    handBuiltPostRefusedTest
    headerPlacementTest
    encodedFieldValueTest
    postWithoutTokenThrowsTest
    postWithoutAntiForgeryTest
    sessionCarriedByJarTest
    maxAgeZeroClearsJarTest

end Tests.Browser
