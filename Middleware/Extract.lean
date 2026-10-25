/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import Middleware.AntiForgery
public import Middleware.Cookies
public import Middleware.Extensions
public import Middleware.Flash
public import Middleware.Params
public import Middleware.Session

public section

open Std.Http
open Routing

namespace Middleware

variable {e : Engine}

/-- Reads something a handler needs from the request, or answers the request with the response
that ends it. -/
abbrev Extractor (e : Engine) (α : Type) :=
  ReaderT (Request e.ReqBody) (ExceptT (Response e.RespBody) e.M) α

/-- Runs `e` against the request, then the handler it produced; a refusal answers the request
instead. What `extract` expands to. -/
def Extractor.handle (x : Extractor e (Result e)) : Result e := fun req => do
  match ← (x.run req).run with
  | .ok handler => handler req
  | .error response => pure response

namespace Extract

/-- Ends the request with `response`. -/
def refuse {α : Type} (response : e.M (Response e.RespBody)) : Extractor e α := do
  throwThe (Response e.RespBody) (← response)

/-- The extractor form of `requiring`, which explains when to reach for it. -/
def required (α : Type) [TypeName α] (missing : StatelessHandler e := defaultMissingExtension) :
    Extractor e α := do
  match (← read).extensions.get α with
  | some value => pure value
  | none => refuse (missing.onRequest (← read))

/-
A specialisation below exists exactly where absence is a fact about the *stack*: `Params`,
`SessionData`, `AntiForgeryToken`, `Flash` and `Cookies` are each inserted unconditionally by their
middleware. `MultipartParams`, `ForwardedFor` and `Scheme` appear only when the request warrants
one, so absence there is a fact about the request, and an extractor refusing on it would reject
every ordinary form post.
-/

/-- `required` for `Params`: absence means no `params` in the stack. -/
def params (missing : StatelessHandler e := defaultMissingExtension) : Extractor e Params :=
  required Params missing

/-- `required` for `SessionData`: absence means no `session` in the stack. -/
def session (missing : StatelessHandler e := defaultMissingExtension) : Extractor e SessionData :=
  required SessionData missing

/-- `required` for `AntiForgeryToken`: absence means no `antiForgery` in the stack. -/
def token (missing : StatelessHandler e := defaultMissingExtension) :
    Extractor e AntiForgeryToken :=
  required AntiForgeryToken missing

/-- `required` for `Flash`: absence means no `flash` in the stack, not that no message waits. -/
def flash (missing : StatelessHandler e := defaultMissingExtension) : Extractor e Flash :=
  required Flash missing

/-- `required` for `Cookies`: absence means no `cookies` in the stack, not that none were sent. -/
def cookies (missing : StatelessHandler e := defaultMissingExtension) : Extractor e Cookies :=
  required Cookies missing

/-- The parameter `name`, as `Params.get` reads it. -/
def field? (name : String) : Extractor e (Option String) :=
  return (← params).get name

/-- The parameter `name`, refusing with a `400` naming it when the request lacks it. -/
def field (name : String) : Extractor e String := do
  match ← field? name with
  | some value => pure value
  | none => refuse (e.text Response.badRequest s!"missing required parameter `{name}`")

end Extract

syntax extractBinder := "(" (ident <|> "_") " ← " term ")"

/--
`extract (x₁ ← e₁) … (xₙ ← eₙ) => body` runs each `eᵢ : Extractor e αᵢ` in turn, binding its
result to `xᵢ` for the extractors after it and for `body`, a `Result e` like the whole. The first
extractor to refuse answers the request, and nothing after it runs.
-/
syntax (name := extractTerm) "extract" (ppSpace extractBinder)+ " => " term : term

macro_rules
  | `(extract $binders:extractBinder* => $body) => do
    let mut acc ← `(pure ($body))
    for binder in binders.reverse do
      acc ← match binder with
        | `(extractBinder| ($x:ident ← $e)) => `(bind $e fun $x => $acc)
        | `(extractBinder| (_ ← $e)) => `(bind $e fun _ => $acc)
        | _ => Lean.Macro.throwUnsupported
    `(Middleware.Extractor.handle $acc)

end Middleware
